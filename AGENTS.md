# AGENTS.md

KernelSU(兼容 Magisk) 模块：让 sing-box 像 systemd 服务一样持久运行（开机自启、崩溃自动重启、**模块启用/禁用开关 = sing-box 开关**、Action 按钮只重启、状态显示在模块描述、WebUI 入口）。

核心价值：本模块跑的是 **reF1nd 分支的 sing-box**（带 `ebpf` 入站），能劫持**热点（网络共享）中其他设备的流量**——这是 SFA 等非 root 方案做不到的，也是这个模块存在的理由。

## 架构（Go 单二进制 + 薄 sh 包装）

守护进程是 **Go，纯标准库，零第三方依赖**，交叉编译成 `aarch64-linux` 静态二进制。

- `src/`
  - `main.go` — 子命令分发 `start|stop|restart|status|watchdog_loop`；`stop` 的顺序是"先停看门狗再停内核"（见坑 15）
  - `app.go` — 路径解析、日志、状态文件、模块描述双写、`describe()`
  - `watchdog.go` — 状态机与主循环；`transition` / `deriveEvent` / `stopEscalation` / `reloadDue` 都是纯函数（可单测）
  - `proc.go` — 子进程句柄、进程归属的严格判定
  - `fs.go` — 文件工具、配置指纹
  - `watchdog_test.go` — 纯函数单测（`go test`）
- `test_local.sh` — 本机端到端：stub 内核 + 全生命周期 + 故障注入（CI 里也跑这个）
- `test_device.sh` — 真机故障注入矩阵（adb 驱动，见下）
- `build.sh` — **唯一构建入口**（本地与 CI 共用，不要另写一套）
- `daemon.sh` / `service.sh` / `action.sh` / `uninstall.sh` / `customize.sh` — 薄 sh 包装与安装脚本
- `config/config.json` — 默认示例配置（唯一 ebpf 入站：`local` 接管本机 + `shared` 示例（默认关）接管热点/USB 下游 + 最小 direct 出站）
- `webroot/` — KernelSU WebUI 入口（加载即跳外部浏览器打开 dashboard）

## 守护进程设计（改之前先读懂这些不变式）

**状态机**：`Disabled / Starting / Running / Stopping / CrashBackoff / Blocked / Exiting`
事件：`DisableOn/Off`、`StopFlag`、`ChildExited`、`StartConfirmed`、`Timeout`、`Reload`、`Unblocked`

1. **进程真相源 = 句柄**（`exec.Cmd`）。pid 文件只是给人看的（描述、`status`）。
2. **只有 `Wait()` 返回（或句柄不存在）才算子进程已死**：发了 SIGTERM 不等于已停止。`Stopping` 里先 TERM，10 秒后 SIGKILL，再等 `Wait()`，然后才进 `Disabled`/`Starting`。
3. **存活/归属判定必须精确**：`ownsProcess` 比对 `/proc/PID/exe` 或 argv 字段（脚本内核的路径在 argv[1]），**不能用"cmdline 含 sing-box"这种子串判断**——看门狗自己的 argv 是 `sing-box-init`，也会命中。
4. **热重载 = 权威重查**：每 tick 对 `conf.d/` 算指纹（文件名+大小+mtime），与"启动时用的指纹"比较；不依赖 inotify 事件（曾经把 inotify 当唯一真相源，事件丢一次就永不重载）。变化后去抖 800ms。
5. **重启前必须 `sing-box check -C <conf.d>`**：校验失败就不重启，旧内核继续跑，日志与模块描述里报"配置错误"；配置改回当前运行版本时自动清掉该标记。
6. 崩溃退避 3 秒；连续稳定运行 60 秒后清零崩溃计数。描述里显示核心版本与崩溃次数，方便一眼看出"是不是新核心搞的"。
7. **看门狗自愈**：panic → 记日志 → 杀掉孤儿内核 → `exec` 自身（**pid 不变**，`flock` 锁随 fd 继承，靠 `SING_BOX_INIT_LOCK_FD` 传递并校验指向锁文件）→ 1 小时内最多 5 次，超限退出。测试钩子：环境变量 `SING_BOX_INIT_TEST_PANIC=<秒>`。
8. **单实例**：`flock` 锁 `$DATA_DIR/.watchdog.lock`。
9. **状态文件** `logs/watchdog.state`：`state / core / crashes / reason / updated`，`status` 与描述都从它 + `/proc` 实测组合出结果。
10. 日志 1MiB 自动截断：`watchdog.log` 写入前检查；`sing-box.log` 每 tick 原地清空（内核长驻持有 fd，rename 旋转没用）。
11. cron/tick 频率 500ms；启动确认 5s、停止宽限 10s、退避 3s、去抖 800ms。

**模块描述双写**：`ksud module config set override.description <desc>` + **原地改写** `module.prop` 的 `description=` 行。
⚠️ 不要改成"写临时文件再 rename"：rename 会把 module.prop 的 SELinux context 换成新文件的，Manager 可能因此读不到它。

## 关键约束（易踩坑）

1. **不要往 `system/` 目录放二进制**：KernelSU 的 system 挂载依赖额外 metamodule。二进制留在 `$MODDIR/bin/`。
2. 剩下的 shell 脚本由 KernelSU 的 BusyBox ash 执行：**纯 POSIX sh**，无 bash 语法。取模块目录用 `MODDIR=${0%/*}`。
3. **zip 安装后文件会失去 +x（真机踩过：刷入后全部 644）**：脚本之间一律 `sh "$MODDIR/xxx.sh"` 调用；二进制由 `customize.sh` 的 `set_perm` 设权限。改脚本要重刷 zip 才生效，adb 直接推文件不触发。
4. **看门狗必须脱离调用方会话**：`start` 用 `SysProcAttr{Setsid: true}` 拉起 `watchdog_loop`（stdin=/dev/null，stdout/stderr → watchdog.log）。
5. **sing-box 必须 cwd=数据目录启动**（`cmd.Dir`）：配置里的 `cache_file` 等相对路径以此解析。在模块目录能跑、从 `/` 跑就是 read-only 崩溃循环（真机踩过）。
6. 运行时文件：配置 `/data/adb/sing-box/conf.d/`、日志 `logs/`（含 `watchdog.state`）、pid 文件 `sing-box.pid` / `sing-box-watchdog.pid`、停止标记 `.stop`、锁 `.watchdog.lock`。**uninstall.sh 有意保留配置**。
7. 停止机制：**正常停止 = 禁用模块**（Manager 开关 → `$MODDIR/disable` 标记 → 看门狗停内核但保持存活，重新启用即自动拉起）。`.stop` 标记只在卸载/`stop` 子命令用。只 kill 死进程的 pid 无法真正停止。
8. **模块开关 = sing-box 开关**。⚠️ 若模块从未被启用过（禁用状态下开机 → `service.sh` 不执行 → 无看门狗），重新启用后不会立即拉起，需点一次 Action 或重启设备。
9. **状态显示时机**：`start` 要等看门狗真正把内核拉起来后再写描述（轮询最多 5 秒）。
10. **不要改 `module.prop` 的 `id`（sing-box-init）**：各脚本有同名兜底路径。
11. 改版本时 `version` 和 `versionCode`（整数）同步；`version` 会被 build.sh 拼进 zip 文件名。纯项目更新只动 `versionCode`。
12. 用户可见输出用中文。代码走"自解释命名"路线：注释只写**为什么**与非显然约束（例：为什么 stop 先停看门狗、为什么 module.prop 不能 rename），不复述代码在做什么。
13. **配置完全由用户维护，守护进程不改写配置**。白名单/热点分流/路由规则都写在 `conf.d/*.json` 里；曾经有过"纯文本 include_package + 生成目录 + JSON 注入"整套机制，已删除，不要再引入。
    - sing-box 只读配置目录里的 `*.json`（其余后缀忽略，见 `cmd/sing-box/cmd_run.go` 的 `readConfig`），所以备份文件放在 `conf.d/` 里只要不叫 `.json` 就不会被解析；不过备份还是建议放到 `$DATA_DIR` 下。
14. 热点劫持（本模块的存在理由）在 1.14 之后由 ebpf 入站的 **`shared` 平面**负责：`shared.enabled: true` + `shared.interface: [...]`（**必填**；列上暂时不存在的接口是安全的，成为默认上游时会自动暂停）。**实测（Xiaomi 14 / HyperOS）**：热点接口是 `wlan2`（`wlan0` 是普通 Wi-Fi 站接口，不要列），USB 共享是 `rndis0`；验证方式是看 `tc filter show dev <iface> ingress` 里有没有 `sb_share_in`（挂的是 ingress，不是 egress）。旧版靠 `local.include_uid: [0]` 蹭内核转发流量（uid 0）的做法已不需要。
    - ⚠️ **ebpf 入站 schema 随版本变**：1.15 已**去掉 `mode` 字段**（旧配置会直接报 `unknown field "mode"`，真机实测），写配置前先看该 tag 下的 `docs/configuration/inbound/ebpf.zh.md` 与 `option/ebpf.go`，不要凭记忆或旧配置抄。
    - ⚠️ `shared` 块存在就要求 shared 被启用：写 `"shared": {"enabled": false, ...}` 会被核心拒绝（`shared options require shared interception`，真机实测）；不启用就整块删掉。同理 `local` 与 `shared` 只要任一侧写了 `enabled`，另一侧省略 `enabled` 就视为 `false`。
    - 不要用 `route.rules[].package_name` 替代 `local.include_package`：它依赖进程可见性，部分构建下不生效（SFA 有实例），而 inbound 的 include/exclude 一直正常。
15. **`stop` 必须先停看门狗、再停内核**。顺序反了就会出现：`stop` 杀掉内核 → 看门狗在中间又拉起一个新内核 → 没人再管它（真机现象："关了模块开关，内核还在跑"）。
16. **看门狗被 `kill -9` 时内核会孤儿化**（这是已知边界：SIGKILL 无法捕获，KernelSU 也没有 init 兜底）。收敛方式：点 Action / 跑 `start`（新看门狗启动时会清理孤儿）或重启设备。panic 才会走自愈路径。
17. 别把 CI 的 tar 校验写成 `tar -tzf x | grep -q ...`：`grep -q` 命中即退出，tar 收到 EPIPE 退出码非 0，`pipefail` 把整条管道判为失败 → 假阴性。曾因此让自动更新静默死掉 10 天。

## 构建与验证

```sh
go test ./...           # 纯函数单测
sh test_local.sh        # 端到端（stub 内核 + 故障注入），CI 也跑这个
sh build.sh             # 交叉编译 aarch64 静态二进制并打包 zip
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/sing-box-init ./src
```

- 构建统一在 CI（`build.sh`），本地不要求装 Go；只是本机测试方便时可以 `nix shell nixpkgs#go`。
- 本机不跑 sing-box 本体、不发版。
- `test_local.sh` 用 `SING_BOX_DATA_DIR=/tmp/...` 重定向数据目录，不需要 root。残留进程清理靠读 pid 文件 + 按 argv 精确匹配（**不能用 `pkill -f`，模式会匹配到自己**）。

## 真机调试（adb）

- **用户的 Manager 是 ResukiSU（com.resukisu.resukisu），不是官方 KernelSU Manager**：它的 WebView 不注入 kernelsu JS API（webroot 页面降级为页面内直接打开，预期行为）；模块列表直接读 module.prop（所以描述要双写）。
- 设备已连 adb（root：`adb shell "su -c '...'"`）。
- 一键验收：`sh test_device.sh`（adb 驱动的故障注入矩阵，见脚本注释；跑之前模块必须已安装）。
- 推送新二进制：`adb push` 到 `/data/local/tmp`，再 `su -c cp` 到 `/data/adb/modules/sing-box-init/bin/sing-box-init` 并 chmod 755。
- `ksud module config list` 查看描述；手动调用需带 `KSU_MODULE=sing-box-init` 前缀。`ksud module action sing-box-init` 模拟 Action 按钮（只做重启）；`ksud module list` 确认描述最终值。
- 验证模块开关：`ksud module disable sing-box-init` → `ls /data/adb/modules/sing-box-init/disable` 应存在、内核进程应消失（约 3 秒内）；`ksud module enable sing-box-init` → 约 3 秒内恢复。
- 核心端口验证：`su -c 'ss -ltn | grep 1235'`、`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1235/dashboard/`（前提是配置里开了 `experimental.clash_api`）。
- 设备上无 wget（toybox 没编译），用 `/system/bin/curl`。
- **toybox 的 `ps -A -o PID,ARGS` 不打印 argv[0] 的路径**（只给 comm + 参数，如 `sing-box run -C ...`），要拿真实 argv[0] 得读 `/proc/<pid>/cmdline`；脚本里判进程一律“先用 ps 找候选 pid，再回 /proc 核对绝对路径”。
- 安装产物验证看 `ls $MODDIR/bin` 与 `/data/adb/sing-box/` 是否存在。

## 核心更新（GitHub Actions 自动构建发布）

- `update.json` — KernelSU Manager 模块更新元数据，`module.prop` 的 `updateJson` 指向它在 GitHub 上的 raw URL。⚠️ 分支是 `ref1nd`，raw URL 必须用 `ref1nd`（工作流用 `GITHUB_REF_NAME` 动态取分支）。
- `.github/workflows/update.yml` — **每天一次** + 手动触发（`force` 强制构建）；`check` 判断要不要构建 → `build` 装 Go → `go vet` + `go test` + `sh test_local.sh` → 下载 arm64 核心 → 改 `module.prop`/`update.json`/`changelog.md` → `build.sh` 打包 → 校验产物（zip 内容齐全 + 二进制必须是 aarch64 ELF）→ push → release；**失败会自动开/更新一个 issue，下次成功自动关闭**（曾经静默变红、链路死了 10 天没人发现）。触发条件：① 核心有新版本；② 项目文件有变化（compare API，排除 `.github/`、`module.prop`、`update.json`、`changelog.md`、README/LICENSE/.gitignore）。
- **核心永远取最新 prerelease**（本模块要的是 reF1nd 分支的新 eBPF 特性，正式版对这里没有意义）。
- ⚠️ 改工作流必看：**先 push 再打 tag**；release 步骤幂等（tag 已存在则覆盖资产）；GitHub API 一律走 `gh api`（匿名 curl 每 IP 每小时 60 次，被限流后旧逻辑会把 `version` 写成 `null`）；不要用 `tar | grep -q` 做校验（见坑 17）。
- `versionCode` 规则：`max(major * 10000 + minor * 100 + 最后数字, 上一次 versionCode + 1)`。
- **纯项目更新（核心未变）**：`version` 保持核心版本不变，只 `versionCode + 1`；release tag 用 `v{version}-r{versionCode}`。

## 版本历史里值得知道的事

- `shell` → `Zig` → `Koka` → **`Go`**（2026-09：旧的 925 行 Koka + 408 行 C 换成约 1250 行 Go（另有 250 行纯逻辑单测），删掉白名单注入、旧格式迁移、Magisk 兼容分支、inotify/signalfd 事件源；换来两个真机 bug 的结构性修复、36 项端到端断言与可单测的纯函数状态机）。
- 迁移前 Koka 版的两个真机 bug（新版的设计正是冲着它们去的）：
  - "关闭模块但内核没关"——`stop-singbox` 发完 TERM 就把 pid 置 0，导致 SIGKILL 升级成了死代码；且只看 pid 文件判断存活。
  - "热重载有时候失效"——inotify 事件是唯一真相源，事件丢了（溢出/非 Running 状态/编辑器写入方式）就永不重载。
