# AGENTS.md

KernelSU (兼容 Magisk) 模块：让 sing-box 像 systemd 服务一样持久运行（开机自启、崩溃自动重启、Action 按钮开关、状态显示在模块描述、WebUI 入口）。

## 结构

- **仓库根目录就是模块根目录**：build.sh 把根目录文件直接打 zip，KernelSU Manager 刷入。
- `bin/` — 随模块附带的 sing-box arm64 tar.gz。**被 .gitignore 忽略但打包必须包含**：customize.sh 安装时解压出 `bin/sing-box` 可执行文件（约 94MB）。删除/改名会破坏安装。
- `config/config.json` — 随模块发布的默认配置，customize.sh 仅在设备上 `/data/adb/sing-box/config.json` 不存在时复制一份，之后不覆盖用户改动。
- `config/bypass-apps.json` — **独立排除文件（按包名直连）**：daemon.sh 用多 `-c` 与主配置合并（sing-box 多 `-c` 合并，数组按序 append，route.rules 追加在 final 兜底之前生效；**不能定义 inbound/outbound 数组，会 duplicate tag 冲突**）。默认排除微信 `com.tencent.mm`、QQ `com.tencent.mobileqq`（设备配置路由无国内直连规则，final=select 全走日本节点 → QQ 延迟/微信红包语音转文字失败，真机确认过）。customize.sh 仅不存在时复制。**reF1nd fork 的 `-c` 不支持配置目录模式，但支持多 `-c`**。
- `daemon.sh` — **核心引擎**（内部脚本，不面向用户）：`start|stop|restart|status|update_desc|watchdog_loop` 子命令 + 看门狗循环 + 把状态写进模块描述。
- `service.sh` — 开机启动钩子，**无参数**（用户要求删掉命令参数）：只调用 `daemon.sh start`。
- `action.sh` — 唯一用户入口：KernelSU Manager 的 Action 按钮 = 开关切换（未运行→启动，运行中/重启中→停止）。
- `customize.sh` — 安装脚本，**被安装器 source 而不是执行**：只能用注入的函数（`ui_print`/`abort`/`set_perm`）和变量（`MODPATH`/`ARCH` 等），不能依赖 cwd。
- `webroot/` — KernelSU WebUI 入口（`index.html` + `icon.png`），webuiIcon 在 module.prop 里声明。index.html 不做状态/开关（那些在描述和 Action 按钮上），**加载即用 `am start` 跳外部浏览器打开 dashboard，并模拟返回键关掉本页**（无 kernelsu API 时降级为页面内打开）。

## 关键约束（易踩坑）

1. **不要往 `system/` 目录放二进制**：KernelSU 的 system 挂载依赖额外 metamodule。二进制必须留在 `$MODDIR/bin/`。
2. 所有脚本在设备上由 KernelSU 的 BusyBox ash（standalone 模式）执行：纯 POSIX sh，无 bash 语法。取模块目录一律用 `MODDIR=${0%/*}`。
2.5. **zip 安装后脚本会失去 +x（真机踩过：刷入后全部 644，`daemon.sh` 直接调用报 `can't execute: Permission denied`，开机/action 全部静默失败）**：脚本之间一律用 `sh "$MODDIR/xxx.sh"` 调用，不依赖可执行位；customize.sh 安装时 `chmod 0755 "$MODPATH"/*.sh` 兜底。改完脚本要重刷 zip 才生效，adb 直接推文件不触发。
3. **看门狗必须脱离调用方会话**：`setsid sh "$MODDIR/daemon.sh" watchdog_loop </dev/null >>log 2>&1 &`（用 sh 前缀，见 2.5）。普通 `( loop ) &` 会在 su/action 会话结束时被一起杀掉，只留下孤儿 sing-box（没有看门狗和有效 pid 文件）→ 状态谎报、关不掉。这是上过真机的教训。
4. **进程存活检查用 `/proc/PID/cmdline` 含 "sing-box" 判断**（`proc_alive`），不要用 `kill -0` 加陈旧 pid 文件——会误判。
5. **sing-box 必须 `cd "$DATA_DIR"` 再启动**：用户配置里的 `cache_file`/dashboard `path` 是相对路径，解析基准是 cwd。在模块目录能跑，从 `/` 跑就是 read-only 崩溃循环（真机踩过）。
6. 运行时文件（设备上）：配置 `/data/adb/sing-box/config.json`、日志 `logs/`、pid 文件 `sing-box.pid` / `sing-box-watchdog.pid`、停止标记 `.stop`、cache.db + dashboard/ 也落在数据目录。**uninstall.sh 有意保留配置**。
7. 停止机制：写 `.stop` 标记，看门狗在循环顶部和 `wait` 之后检查。只 kill 死进程的 pid 无法真正停止（看门狗 3 秒后会重新拉起）。
8. **状态显示在模块描述**：`update_desc` **双写**——`ksud module config set override.description`（需 `KSU_MODULE` 环境变量，脚本里已 export 兜底）+ `sed -i` 改写 module.prop 的 description 行（ResukiSU 等 Manager 可能直接读 module.prop）。**时机竞态（真机踩过）**：必须等看门狗真正拉起 sing-box 后再写（`start` 里轮询最多 5 秒），action.sh 不要自己调 update_desc，由 daemon.sh 的 start/stop 内部负责。
9. **不要改 module.prop 的 `id`（sing-box-init）**：webroot/index.html 硬编码 `/data/adb/modules/sing-box-init/daemon.sh`，各脚本也有同名兜底路径。
10. 改版本时 `version` 和 `versionCode`（整数）要同步；`version` 会被 build.sh 拼进 zip 文件名。
11. 用户可见输出和注释用中文（现有风格）。

## 本机验证（不要真的跑设备逻辑）

- 语法检查：`sh -n *.sh`。
- daemon.sh/uninstall.sh 用 `SING_BOX_DATA_DIR=/tmp/...` 环境变量重定向数据目录，避免触碰 `/data/adb`（需要 root，`sudo` 会剥离该环境变量，需用 `sudo env SING_BOX_DATA_DIR=...`）。
- customize.sh：在 stub 了 `abort`/`ui_print`/`set_perm` 后 source 它，`MODPATH` 指向临时目录。
- **看门狗是死循环，这是设计行为（对应 Restart=always），绝不会自己退出**：测试时用 stub 二进制（真实 sing-box 是 arm64 ELF，本机跑不了），测完必须立即清理——后台测试进程若以 root 启动（sudo），用普通 `kill` 会因权限不足失败，要 `sudo kill -9`，且 `pkill -f` 的模式不能匹配自身命令行里的路径字符串。

## 真机调试（adb）

- **用户的 Manager 是 ResukiSU（com.resukisu.resukisu），不是官方 KernelSU Manager**：它的 WebView 不注入 kernelsu JS API（webroot 页面无法用 `ksu.exec` 在外部浏览器打开，会降级为页面内直接打开，这是预期行为，不是 bug）；模块列表可能直接读 module.prop（所以才要双写描述）。
- 设备已连 adb（root：`adb shell "su -c '...'"`）。改模块脚本可直接推送到 `/data/adb/modules/sing-box-init/`（`adb push` 要先放 `/data/local/tmp` 再 `su -c cp`，再 chmod 755），不用重刷模块。
- `ksud module config list` 查看描述/配置（手动调用需带 `KSU_MODULE=sing-box-init` 前缀）。
- 用 `ksud module action sing-box-init` 模拟 Manager 的 Action 按钮（能看到 action.sh 的输出）；`ksud module list` 可确认描述字段最终值。
- 核心端口验证：`su -c 'ss -ltn | grep 1235'`、`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1235/dashboard/`。
- 设备上无 wget（toybox 没编译），用 curl（/system/bin/curl 存在）。
- 安装/卸载产物验证看 `ls $MODDIR/bin` 与 `/data/adb/sing-box/` 是否存在。

## 构建

```sh
./build.sh   # 输出 sing-box-init-v<version>.zip，唯一依赖是 zip 命令
```
