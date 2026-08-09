# AGENTS.md

KernelSU (兼容 Magisk) 模块：让 sing-box 像 systemd 服务一样持久运行（开机自启、崩溃自动重启、**模块启用/禁用开关 = sing-box 开关**、Action 按钮只重启、状态显示在模块描述、WebUI 入口）。

## 结构

- **仓库根目录就是模块根目录**：build.sh 把根目录文件直接打 zip，KernelSU Manager 刷入。
- `bin/` — 随模块附带的 sing-box arm64 tar.gz。**被 .gitignore 忽略但打包必须包含**：customize.sh 安装时解压出 `bin/sing-box` 可执行文件（约 94MB）。删除/改名会破坏安装。
- `config/config.json` — 随模块发布的默认配置，customize.sh 仅在设备上 `/data/adb/sing-box/conf.d/config.json` 不存在时复制一份（若旧位置 `/data/adb/sing-box/config.json` 存在则先迁移），之后不覆盖用户改动。
- `config/bypass-apps.json` — **独立排除文件（按包名直连）**：丢进 `conf.d/` 目录，daemon.sh 用 `-C`（目录模式）合并 conf.d/ 下所有 json（**不能定义 inbound/outbound 数组，会 duplicate tag 冲突**）。默认排除微信 `com.tencent.mm`、QQ `com.tencent.mobileqq`（设备配置路由无国内直连规则，final=select 全走日本节点 → QQ 延迟/微信红包语音转文字失败，真机确认过）。customize.sh 仅不存在时复制。
- `daemon.sh` — **核心引擎**（内部脚本，不面向用户）：`start|stop|restart|status|update_desc|watchdog_loop` 子命令 + 常驻看门狗循环（模块开关决定 sing-box 启停，见约束 12）+ 把状态写进模块描述。配置用 `-C` 目录模式（`conf.d/`），回退到 `-c` 单文件模式。
- `service.sh` — 开机启动钩子，**无参数**（用户要求删掉命令参数）：只调用 `daemon.sh start`。
- `action.sh` — 唯一用户入口：KernelSU Manager 的 Action 按钮 = **只重启**（`stop` + `start`），只调 `daemon.sh restart` 一个子命令。开关 sing-box 用模块本身的启用/禁用开关。
- `customize.sh` — 安装脚本，**被安装器 source 而不是执行**：只能用注入的函数（`ui_print`/`abort`/`set_perm`）和变量（`MODPATH`/`ARCH` 等），不能依赖 cwd。
- `webroot/` — KernelSU WebUI 入口（`index.html` + `icon.png`），webuiIcon 在 module.prop 里声明。index.html 不做状态/开关（那些在描述和 Action 按钮上），**加载即用 `am start` 跳外部浏览器打开 dashboard，并模拟返回键关掉本页**（无 kernelsu API 时降级为页面内打开）。

## 关键约束（易踩坑）

1. **不要往 `system/` 目录放二进制**：KernelSU 的 system 挂载依赖额外 metamodule。二进制必须留在 `$MODDIR/bin/`。
2. 所有脚本在设备上由 KernelSU 的 BusyBox ash（standalone 模式）执行：纯 POSIX sh，无 bash 语法。取模块目录一律用 `MODDIR=${0%/*}`。
2.5. **zip 安装后脚本会失去 +x（真机踩过：刷入后全部 644，`daemon.sh` 直接调用报 `can't execute: Permission denied`，开机/action 全部静默失败）**：脚本之间一律用 `sh "$MODDIR/xxx.sh"` 调用，不依赖可执行位；customize.sh 安装时 `chmod 0755 "$MODPATH"/*.sh` 兜底。改完脚本要重刷 zip 才生效，adb 直接推文件不触发。
3. **看门狗必须脱离调用方会话**：`setsid sh "$MODDIR/daemon.sh" watchdog_loop </dev/null >>log 2>&1 &`（用 sh 前缀，见 2.5）。普通 `( loop ) &` 会在 su/action 会话结束时被一起杀掉，只留下孤儿 sing-box（没有看门狗和有效 pid 文件）→ 状态谎报、关不掉。这是上过真机的教训。
4. **进程存活检查用 `/proc/PID/cmdline` 含 "sing-box" 判断**（`proc_alive`），不要用 `kill -0` 加陈旧 pid 文件——会误判。
5. **sing-box 必须 `cd "$DATA_DIR"` 再启动**：用户配置里的 `cache_file`/dashboard `path` 是相对路径，解析基准是 cwd。在模块目录能跑，从 `/` 跑就是 read-only 崩溃循环（真机踩过）。
6. 运行时文件（设备上）：配置 `/data/adb/sing-box/conf.d/config.json`、日志 `logs/`、pid 文件 `sing-box.pid` / `sing-box-watchdog.pid`、停止标记 `.stop`、cache.db + dashboard/ 也落在数据目录。**uninstall.sh 有意保留配置**。
7. 停止机制：**正常停止 = 禁用模块**（Manager 开关 → 模块目录出现 `disable` 文件，看门狗轮询到后停掉 sing-box 并保持监听，重新启用即自动拉起，见约束 12）。显式停止（仅卸载用）写 `.stop` 标记 + TERM 看门狗。只 kill 死进程的 pid 无法真正停止（看门狗几秒后会重新拉起）。
8. **状态显示在模块描述**：`update_desc` **双写**——`ksud module config set override.description`（需 `KSU_MODULE` 环境变量，脚本里已 export 兜底）+ `sed -i` 改写 module.prop 的 description 行（ResukiSU 等 Manager 可能直接读 module.prop）。**时机竞态（真机踩过）**：必须等看门狗真正拉起 sing-box 后再写（`start` 里轮询最多 5 秒），action.sh 不要自己调 update_desc，由 daemon.sh 的 start/stop 内部负责。
9. **不要改 module.prop 的 `id`（sing-box-init）**：webroot/index.html 硬编码 `/data/adb/modules/sing-box-init/daemon.sh`，各脚本也有同名兜底路径。
10. 改版本时 `version` 和 `versionCode`（整数）要同步；`version` 会被 build.sh 拼进 zip 文件名。（例外：工作流的纯项目更新只动 `versionCode`，`version` 跟随核心版本不变。）
11. 用户可见输出和注释用中文（现有风格）。
12. **模块开关 = sing-box 开关**（用户需求）：KernelSU/Magisk 的 Manager 禁用/启用模块 = 在模块目录创建/删除 `disable` 标记文件（ksud 源码 `disable_module`/`enable_module` 确认：只动标记文件、不执行任何脚本；禁用模块时开机也不跑 service.sh）。daemon.sh 的 `module_disabled()` 检查 `$MODDIR/disable`（另有 `remove` 待卸载标记、模块目录不存在兜底），看门狗每 3 秒轮询，禁用 → 停 sing-box 且看门狗保持存活，重新启用 → 自动拉起。⚠️ 若模块从未被启用过（禁用状态下开机 → service.sh 不执行 → 无看门狗），重新启用模块后不会立即拉起，需点一次 Action（重启）或重启设备。

## 本机验证（不要真的跑设备逻辑）

- 语法检查：`sh -n *.sh`。
- daemon.sh/uninstall.sh 用 `SING_BOX_DATA_DIR=/tmp/...` 环境变量重定向数据目录，避免触碰 `/data/adb`（需要 root，`sudo` 会剥离该环境变量，需用 `sudo env SING_BOX_DATA_DIR=...`）。
- customize.sh：在 stub 了 `abort`/`ui_print`/`set_perm` 后 source 它，`MODPATH` 指向临时目录。
- **看门狗是常驻监听进程（模块禁用时也活着），绝不自己退出，这是设计行为**：测试时用 stub 二进制（真实 sing-box 是 arm64 ELF，本机跑不了），测完必须立即清理——后台测试进程若以 root 启动（sudo），用普通 `kill` 会因权限不足失败，要 `sudo kill -9`，且 `pkill -f` 的模式不能匹配自身命令行里的路径字符串。

## 真机调试（adb）

- **用户的 Manager 是 ResukiSU（com.resukisu.resukisu），不是官方 KernelSU Manager**：它的 WebView 不注入 kernelsu JS API（webroot 页面无法用 `ksu.exec` 在外部浏览器打开，会降级为页面内直接打开，这是预期行为，不是 bug）；模块列表可能直接读 module.prop（所以才要双写描述）。
- 设备已连 adb（root：`adb shell "su -c '...'"`）。改模块脚本可直接推送到 `/data/adb/modules/sing-box-init/`（`adb push` 要先放 `/data/local/tmp` 再 `su -c cp`，再 chmod 755），不用重刷模块。
- `ksud module config list` 查看描述/配置（手动调用需带 `KSU_MODULE=sing-box-init` 前缀）。
- 用 `ksud module action sing-box-init` 模拟 Manager 的 Action 按钮（能看到 action.sh 的输出，现在只做重启）；`ksud module list` 可确认描述字段最终值。
- 验证模块开关：`ksud module disable sing-box-init` 后 `ls /data/adb/modules/sing-box-init/disable` 应存在、`ss -ltn | grep 1235` 应消失（约 3 秒内）；`ksud module enable sing-box-init` 后约 3 秒内恢复监听。
- 核心端口验证：`su -c 'ss -ltn | grep 1235'`、`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1235/dashboard/`。
- 设备上无 wget（toybox 没编译），用 curl（/system/bin/curl 存在）。
- 安装/卸载产物验证看 `ls $MODDIR/bin` 与 `/data/adb/sing-box/` 是否存在。

## 构建

```sh
./build.sh   # 输出 sing-box-init-v<version>.zip，唯一依赖是 zip 命令
```

## 核心更新（GitHub Actions 自动构建发布）

- `update.json` — KernelSU Manager 模块更新元数据，`module.prop` 的 `updateJson` 字段指向此文件在 GitHub 上的 raw URL。
- `.github/workflows/update.yml` — GitHub Actions 工作流：每 6 小时 + 手动触发，自动检测 `reF1nd/sing-box-releases` 最新 testing（prerelease）版本，下载 arm64 tar.gz → 更新 `module.prop` + `update.json` → `build.sh` 打包 → `gh release create` 发布 → git commit + push。**构建触发条件有两个，满足任一即构建**：① sing-box 核心有新版本；② 项目文件有更新（用 GitHub compare API 对比上次 release 到 HEAD，排除 `.github/`、`module.prop`、`update.json`、`changelog.md`、README/LICENSE/.gitignore——这些都是工作流自己维护或无关的，防止工作流自己的提交再次触发构建）。
- **首次推送前**：把 `module.prop` 和 `update.json` 里的 `YOUR_GITHUB_USERNAME` 替换为实际 GitHub 用户名。
- **触发方式**：定时（每 6 小时）+ 手动 `workflow_dispatch`（在 GitHub Actions 页面点 Run workflow）。
- **设备端**：KernelSU Manager 检测到 `update.json` 版本变化 → 显示更新按钮 → 用户点击 → 下载 zip 并安装（等同于刷入新模块）。
- `versionCode` 规则：`max(major * 10000 + minor * 100 + 最后数字, 上一次 versionCode + 1)`，保证单调递增（防止 beta 转 stable 等版本回退、以及纯项目更新时 versionCode 倒退导致 Manager 不提示更新）。
- **纯项目更新（核心未变）**：`version` 保持核心版本不变，只 `versionCode + 1`；release tag 用 `v{version}-r{versionCode}`（如 `v1.14.0-beta.8-r11409`，避免与核心更新的 `v{version}` tag 冲突），zip 文件名不变（`build.sh` 用 `version` 拼名）。
