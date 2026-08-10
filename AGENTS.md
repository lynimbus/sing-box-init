# AGENTS.md

KernelSU (兼容 Magisk) 模块：让 sing-box 像 systemd 服务一样持久运行（开机自启、崩溃自动重启、**模块启用/禁用开关 = sing-box 开关**、Action 按钮只重启、状态显示在模块描述、WebUI 入口）。

## 架构（2026-08-11 起：Zig 核心 + shell 包装）

守护进程逻辑已从 shell 迁移到 **Zig**（可读性优先，其次性能）。设备上跑的是 `aarch64-linux-musl` 静态二进制（约 200KB，无 libc 依赖）。

- `src/` — Zig 源码（设备端守护进程 + 白名单生成）
  - `main.zig` — 入口：子命令分发 `start|stop|restart|status|update_desc|watchdog_loop`，模块目录/数据目录解析。argv 与 env 从 `/proc/self/cmdline`、`/proc/self/environ` 读取（不依赖 dev 版变动频繁的 std.process args/env API）
  - `context.zig` — `Context`：集中管理路径/IO/日志/进程（0.17 版 std 全面 Io 化后的收拢点）。含 `log`（时间戳用 `date` 子进程，与 shell 版格式一致）、`pidAlive`（/proc 检查）、`moduleDisabled`、`updateDesc`（双写）、`spawnQuiet`/`reap` 等
  - `daemon.zig` — 子命令入口：start/stop/restart/status/watchdog_loop
  - `watchdog.zig` — **看门狗引擎：显式状态机 + 事件驱动**（2026-08-11 方案 B）
    - 状态：`disabled / starting / running / stopping / crash_backoff / exiting`
    - 事件：`disable_on/off`、`stop_flag`、`whitelist_changed`、`singbox_started/exited`、`timeout`
    - 事件源：**inotify**（监听 $MODDIR 与 $DATA_DIR，disable/.stop/include_package 变化即时唤醒）+ **signalfd**（阻塞 SIGCHLD，sing-box 退出即时得知）+ poll 定时器（按状态精确控制拉起确认 5s / 强杀 10s / 崩溃退避 3s）
    - `transition()` 是纯函数（无副作用，可单测）；`tick()` 每次仍**全量重查标志**作权威，事件丢失最多退化为 3s 轮询（不劣于旧版）
    - **白名单热重载**：include_package 变化（inotify CLOSE_WRITE/MOVED_TO）→ 自动重启 sing-box
    - **配置热重载**：`conf.d/` 下任意 `*.json` 变化 → 自动重启（编辑器保存/原子替换都覆盖）；生成目录 `conf.d.generated/` 是 watch 盲区（自己写的），不会无限重启循环
    - 热重载统一**去抖 800ms**（`reload_deadline`）：编辑器保存的多事件/连续修改自动顺延，稳定后一次重启
  - `whitelist.zig` — 应用白名单生成（替代旧 whitelist.sh + whitelist.awk）
  - `tests.zig` — 单元测试（`zig build test`，白名单注入逻辑 + pidAlive）
- `build.zig` / `build.zig.zon` — Zig 构建配置（`exe.single_threaded = true`：看门狗是纯轮询进程，无线程更可靠）
- `daemon.sh` — **薄 sh 包装**：`exec "$MODDIR/bin/sing-box-init" "$@"`。保留本文件名是为了兼容既有调用链（service.sh/action.sh/uninstall.sh 都用 `sh daemon.sh <子命令>`，不依赖可执行位）
- `service.sh` / `action.sh` / `uninstall.sh` — 不变，仍调 `sh "$MODDIR/daemon.sh" ...`
- `customize.sh` — 安装脚本（被安装器 source），新增 `set_perm "$MODPATH/bin/sing-box-init"`（zip 解压可能丢 +x）
- `build.sh` — 构建：`zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall` → 复制二进制到 `bin/` → zip 打包
- `test_local.sh` — 本机端到端测试（stub sing-box，全生命周期验证）
- `bin/` — 随模块附带的 sing-box arm64 tar.gz（**被 .gitignore 忽略但打包必须包含**）+ 构建时生成的 `sing-box-init` 二进制（也是 gitignored）。customize.sh 安装时解压出 `bin/sing-box`（约 94MB）
- `config/config.json` — **默认示例配置**（含唯一 ebpf 入站 + 最小 direct 出站 + geoip-cn-nodoh 规则集）。⚠️ **合并语义**：数组追加、对象递归合并——conf.d 下其他文件不要再定义 ebpf/其他 inbound/outbound 数组（会 duplicate tag 冲突）；设备上遗留的旧版 `conf.d/bypass-apps.json` 应删掉（customize.sh 只在 conf.d/config.json 不存在时自动清理）
- `config/include_package` — **应用白名单（纯文本，用户唯一要编辑的文件）**：每行一个包名（空行、`#` 注释忽略），列出的应用走代理，其余（ebpf 模式）内核层绕过。⚠️ 包名只在启动时解析，改后需重启（Action 按钮）；清空文件 = 全部应用走代理。**开关：改名成 `include_package.disable` 即关闭白名单**（两者都存在时以 `include_package` 为准；已禁用状态下更新/重装不会重新生成）
- `webroot/` — KernelSU WebUI 入口（index.html + icon.png）。加载即跳外部浏览器打开 dashboard

## Zig 版白名单生成（whitelist.zig，替代旧 shell 版）

旧版用 awk 做文本注入（容忍非严格 JSON）；新版用 `std.json` **严格解析**，流程（对应旧 whitelist.sh）：

1. 重建生成目录 `conf.d.generated/`：清旧 json → 复制 `conf.d/` 下所有 `*.json`
2. `include_package` 不存在（或改名 `.disable`）→ 白名单关闭，配置原样加载
3. 过滤白名单文件（空行/`#` 注释/首尾空白/`\r`）
4. 递归找每个文件里 `type == "ebpf"` 的对象（任意深度），`include_package` 整体替换/插入；含 ebpf 的文件重新序列化（缩进 2 空格，便于排查），其余保持原样
5. 所有文件都无 ebpf（如 tun 模式）→ 写路由规则 `00-include-package.json`（`package_name` + `action: route`）

**严格语义（2026-08-11 定案）**：任一配置文件非法 JSON → 生成失败，daemon 回退直接用原始 conf.d（sing-box 报真实错误，watchdog.log 里先给出明确提示）。用户配置写不合法，sing-box 反正起不来，不静默放过。

## 关键约束（易踩坑）

1. **不要往 `system/` 目录放二进制**：KernelSU 的 system 挂载依赖额外 metamodule。二进制必须留在 `$MODDIR/bin/`。
2. 剩余 shell 脚本（包装/安装）由 KernelSU 的 BusyBox ash（standalone 模式）执行：纯 POSIX sh，无 bash 语法。取模块目录一律用 `MODDIR=${0%/*}`。
2.5. **zip 安装后文件会失去 +x（真机踩过：刷入后全部 644）**：脚本之间一律用 `sh "$MODDIR/xxx.sh"` 调用，不依赖可执行位；Zig 二进制由 customize.sh `set_perm` 设权限；改脚本要重刷 zip 才生效，adb 直接推文件不触发。
3. **看门狗必须脱离调用方会话**：`start` 用 `std.process.spawn` 以自身路径（`executablePathAlloc`）拉起 `watchdog_loop` 子进程（stdin=/dev/null，stdout/stderr → watchdog.log），子进程第一件事 `setsid()`。普通 `( loop ) &` 会在 su/action 会话结束时被一起杀掉。⚠️ **spawn 的子进程环境来自 `Io.Threaded` 自带环境（默认空）**：`main` 必须用 `context.currentEnviron()`（读 /proc/self/environ）传给 `Threaded.init`，否则子进程丢 PATH 和 SING_BOX_DATA_DIR（真机/本机都踩过）。
4. **进程存活检查用 `/proc/PID/cmdline` 含 "sing-box" 判断**（`pidAlive`），不要用 `kill -0`——`kill -0` 对僵尸进程也返回成功，会误判（真机踩过：stub 被杀后变 `<defunct>`，测试误报"还在跑"）。
5. **sing-box 必须 cwd=数据目录启动**（`spawn .cwd = .{ .path = data_dir }`）：配置里的 `cache_file`/dashboard `path` 相对路径以此解析。在模块目录能跑，从 `/` 跑就是 read-only 崩溃循环（真机踩过）。
6. 运行时文件（设备上）：配置 `/data/adb/sing-box/conf.d/config.json`、白名单 `include_package`、生成目录 `conf.d.generated/`（每次启动重建）、日志 `logs/`、pid 文件 `sing-box.pid` / `sing-box-watchdog.pid`、停止标记 `.stop`。**uninstall.sh 有意保留配置**。
7. 停止机制：**正常停止 = 禁用模块**（Manager 开关 → 模块目录出现 `disable` 文件，看门狗轮询到后停掉 sing-box 并保持监听，重新启用即自动拉起）。显式停止（仅卸载用）写 `.stop` 标记 + TERM 看门狗。只 kill 死进程的 pid 无法真正停止。
8. **状态显示在模块描述**：`updateDesc` **双写**——ksud `module config set override.description`（⚠️ spawn 前先查 ksud 在 PATH，否则 fork 后 exec 失败留僵尸）+ 改写 module.prop 的 description 行（ResukiSU 等 Manager 直接读 module.prop）。**时机竞态（真机踩过）**：必须等看门狗真正拉起 sing-box 后再写（`start` 里轮询最多 5 秒），action.sh 不要自己调 update_desc。
9. **不要改 module.prop 的 `id`（sing-box-init）**：各脚本有同名兜底路径。
10. 改版本时 `version` 和 `versionCode`（整数）要同步；`version` 会被 build.sh 拼进 zip 文件名。（例外：工作流的纯项目更新只动 `versionCode`，`version` 跟随核心版本不变。）
11. 用户可见输出和注释用中文（现有风格）。Zig 代码同样中文注释。
12. **模块开关 = sing-box 开关**（用户需求）：Manager 禁用/启用模块 = 创建/删除 `disable` 标记文件（ksud 只动标记文件）。`moduleDisabled()` 检查 `$MODDIR/disable`（另有 `remove` 待卸载标记、模块目录不存在兜底），看门狗每 3 秒轮询，禁用 → 停 sing-box 且看门狗保持存活，重新启用 → 自动拉起。⚠️ 若模块从未被启用过（禁用状态下开机 → service.sh 不执行 → 无看门狗），重新启用后不会立即拉起，需点一次 Action 或重启设备。
13. **僵尸进程**：看门狗用 pid 管理 sing-box（不是 Child 句柄），停止/重启后必须 `reap()`（waitpid）收尸，否则进程表泄漏（本机 e2e 踩过）。同理**不要 spawn 不存在的命令**（ksud 先查 PATH）。状态机版在 tick 里统一 `waitpid(-1, WNOHANG)` 收割所有子进程。
14. **事件驱动实现细节（watchdog.zig）**：
    - signalfd 的 read 缓冲区必须 ≥ `sizeof(signalfd_siginfo)`（128B），否则 EINVAL panic（真机踩过）
    - 阻塞 SIGCHLD 后 `process.run`/`waitpid` 不受影响；date/ksud 等辅助进程的 SIGCHLD 也会唤醒 poll，收割后忽略
    - inotify 只负责"提前唤醒"和 include_package 变化提示；disable/.stop 标志由 tick 全量重查（权威）
    - 热重载只消费 running 状态的 reload 事件（白名单/配置）；starting/disabled 收到则丢弃（重新生成配置时会覆盖）
    - **⚠️ inotify `len` 字段不可信**：实测本内核把所有事件的 len 恒报为 16（name 区域圆整到 16 字节），必须用 **NUL 截断**解析 name（`eventName`），否则长短不一的文件名全部匹配失败（真机踩过，include_package 热重载曾因此静默失效）
    - 事件源初始化失败 → 优雅降级为纯 3s 轮询（行为同旧版）

## Zig / 0.17-dev 特有坑（写代码必看）

- 本机 Zig 0.17.0-dev.1567（Arch pacman），CI 锁官方 master 快照 0.17.0-dev.1662（mlugg/setup-zig，见 update.yml）。两者 std API 已验证兼容。**dev 版 API 随时会变，升级前先跑 `zig build test` + `test_local.sh`**。
- `std.Io.Dir.openDirAbsolute` 默认 **O_PATH** 打开（不可迭代）——`iterate` 必须传 `.iterate = true`（否则 getdents/lseek EBADF 崩溃）。
- **/proc 文件 stat size 恒为 0**：不能先 stat 再读（readFileAlloc 会读到空），用 `readProcFile`（固定缓冲区 read 循环）。
- `Threaded.io()` 的 `userdata` 指向 Threaded 实例自身：**实例不能拷贝/移动**（测试里堆分配），`std.testing.io` 在 dev 版未初始化（vtable 是垃圾值），测试要自建 `Io.Threaded`。
- `process.spawn` 的 `StdIo.file` 把已打开的 fd 传给子进程（共享 open file description）——日志用 `openat(O_APPEND)` 打开即可天然追加，无需 seek。
- `std.ArrayList(T)` 是 stateless 的（方法带 gpa 参数）；`std.json.Array` 是 `Managed`（init 带 allocator）。`ObjectMap.put(a, key, value)` 带 allocator；`ObjectMap` 构造用 `.empty`。
- `single_threaded = true`（build.zig）：无后台线程，fork/spawn 语义简单。

## 本机验证（不要真的跑设备逻辑）

- 语法检查（shell 包装）：`sh -n *.sh`。
- Zig 单测：`zig build test`（白名单注入/替换/路由规则/非法 JSON/过滤/pidAlive）。
- 端到端：`sh test_local.sh`——在 /tmp/sbx-e2e 下建假模块目录 + stub sing-box（`#!/bin/sh while true; sleep 10`），走 start→白名单验证→**禁用（事件驱动 <1s）**→重新启用→**崩溃 kill -9 即时检测+自动恢复**→**白名单热重载**→**配置热重载（改 conf.d/config.json）+ 无重启循环验证**→stop 全流程，验证 pid 文件与零残留。**注意：残留进程清理靠读旧 pid 文件 kill（不能用 pkill -f，模式会匹配到自己的命令行）**。
- 交叉编译设备版：`zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall`（产物 zig-out/bin/sing-box-init）。
- 本机测试用 `SING_BOX_DATA_DIR=/tmp/...` 环境变量重定向数据目录（二进制原生支持，不需要 sudo）。

## 真机调试（adb）

- **用户的 Manager 是 ResukiSU（com.resukisu.resukisu），不是官方 KernelSU Manager**：它的 WebView 不注入 kernelsu JS API（webroot 页面降级为页面内直接打开，预期行为）；模块列表可能直接读 module.prop（所以才要双写描述）。
- 设备已连 adb（root：`adb shell "su -c '...'"`）。推送新二进制：`adb push` 到 `/data/local/tmp` 再 `su -c cp` 到 `/data/adb/modules/sing-box-init/bin/sing-box-init`，chmod 755。
- `ksud module config list` 查看描述/配置（手动调用需带 `KSU_MODULE=sing-box-init` 前缀）。
- `ksud module action sing-box-init` 模拟 Action 按钮（现在只做重启）；`ksud module list` 确认描述最终值。
- 验证模块开关：`ksud module disable sing-box-init` 后 `ls /data/adb/modules/sing-box-init/disable` 应存在、`ss -ltn | grep 1235` 应消失（约 3 秒内）；`ksud module enable sing-box-init` 后约 3 秒内恢复监听。
- 核心端口验证：`su -c 'ss -ltn | grep 1235'`、`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1235/dashboard/`。
- 白名单验证：改 `/data/adb/sing-box/include_package` → Action 重启 → 看 `/data/adb/sing-box/conf.d.generated/` 下对应文件的 `include_package`（ebpf 注入）或 `00-include-package.json`（路由规则）；`su -c 'grep -A3 include_package /data/adb/sing-box/conf.d.generated/config.json'`。
- 白名单开关验证：`su -c 'mv /data/adb/sing-box/include_package /data/adb/sing-box/include_package.disable'` → Action 重启 → `conf.d.generated/` 应与 conf.d 完全一致，`logs/watchdog.log` 有 `whitelist disabled` 记录；`mv` 回去即恢复。
- 设备上无 wget（toybox 没编译），用 curl（/system/bin/curl 存在）。
- 安装/卸载产物验证看 `ls $MODDIR/bin` 与 `/data/adb/sing-box/` 是否存在。

## 构建

```sh
./build.sh   # 输出 sing-box-init-v<version>.zip; 依赖 zig (0.17-dev) + zip 命令
```

（build.sh 先 `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall`，把二进制复制进 `bin/` 再打包；zip 内容含 daemon.sh 包装 + bin/ 下 sing-box 内核 tar.gz 与 zig 二进制。）

## 核心更新（GitHub Actions 自动构建发布）

- `update.json` — KernelSU Manager 模块更新元数据，`module.prop` 的 `updateJson` 字段指向此文件在 GitHub 上的 raw URL。
- `.github/workflows/update.yml` — 每 6 小时 + 手动触发，自动检测 `reF1nd/sing-box-releases` 最新 testing 版本，下载 arm64 tar.gz → 更新 `module.prop` + `update.json` → **安装 Zig（mlugg/setup-zig，锁 0.17.0-dev.1662）** → `build.sh` 打包 → `gh release create` → git commit + push。构建触发条件：① sing-box 核心有新版本；② 项目文件有更新（compare API 对比上次 release 到 HEAD，排除 `.github/`、`module.prop`、`update.json`、`changelog.md`、README/LICENSE/.gitignore）。
- **首次推送前**：把 `module.prop` 和 `update.json` 里的 `YOUR_GITHUB_USERNAME` 替换为实际 GitHub 用户名。
- `versionCode` 规则：`max(major * 10000 + minor * 100 + 最后数字, 上一次 versionCode + 1)`，保证单调递增。
- **纯项目更新（核心未变）**：`version` 保持核心版本不变，只 `versionCode + 1`；release tag 用 `v{version}-r{versionCode}`；zip 文件名不变。
