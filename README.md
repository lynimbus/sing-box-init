# sing-box init

KernelSU / Magisk 模块：把[官方 sing-box](https://github.com/SagerNet/sing-box)（上游 SagerNet）当作常驻服务跑起来。

**它解决什么**：root 级透明代理常驻运行——开机自启、崩溃自动重启、模块开关就是 sing-box 开关；`tun` 入站的 `auto_redirect` 能**劫持热点（网络共享）中其他设备的流量**，这是 SFA 之类非 root 方案做不到的。

> 本仓库两个书签：`main` 跟 [reF1nd 分支核心](https://github.com/reF1nd/sing-box-releases)（带 `ebpf` 入站），`official`（本分支）跟官方核心、用 `tun` + `auto_redirect`。两边安装包不通用，各自的 `updateJson` 指向自己的分支。

## 安装

从 [Releases](https://github.com/lynimbus/sing-box-init/releases) 下载 zip，在 KernelSU Manager 里刷入，重启设备生效。之后的版本更新会出现在 Manager 的模块更新里（自动构建发布）。

## 配置

配置放在 **`/data/adb/sing-box/conf.d/`**，目录下所有 `*.json` 会被合并（数组追加、对象递归合并——**不要在两个文件里定义同 tag 的 inbound/outbound**；目录里非 `.json` 后缀的文件会被忽略）。首次安装会生成一份默认示例配置。

守护进程**不改写你的配置**：接管范围完全由你写在配置里。

改完配置**不用手动重启**：守护进程检测到 `conf.d/` 变化（去抖 0.8 秒）会先跑 `sing-box check` 校验，通过才重启内核；**配置写错不会打断你正在用的网络**，旧内核继续跑，错误会显示在模块描述里。

## 使用

| 操作 | 效果 |
|---|---|
| Manager 里的模块启用/禁用开关 | sing-box 开 / 关（禁用时守护进程仍存活，重新启用会自动拉起） |
| Action 按钮 | 重启 sing-box |
| 模块描述 | 实时状态：运行中 (pid, 核心版本, 崩溃次数) / 启动受阻原因 / 已禁用 |
| WebUI 入口 | 打开 sing-box dashboard（需要在配置里加 `services` 里的 `api` 服务，`listen_port` 如 1235） |

日志在 `/data/adb/sing-box/logs/`：`watchdog.log` 看守护进程（超过 1MiB 自动截断）；`sing-box.log` 看内核，**每次启动内核都会轮转一次**，只保留最近三次启动（`sing-box.log` 与 `sing-box.log.1` / `.2`），每个文件超过 256KiB 就地截断。卸载模块**不会**删除 `/data/adb/sing-box/`，配置会保留。

## 构建

```sh
./build.sh          # 交叉编译 aarch64 静态二进制并打包 zip（需要 go + zip）
go test ./...       # 纯逻辑单测
sh test_local.sh    # 本机端到端（stub 内核 + 故障注入）
sh test_device.sh   # 真机故障注入矩阵（需要 adb + 已安装模块）
```

守护进程是纯 Go 标准库实现的单二进制（无第三方依赖），核心代码在 `src/`，设计约束见 [AGENTS.md](AGENTS.md)。
