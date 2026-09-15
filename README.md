# sing-box init

KernelSU / Magisk 模块：把 [reF1nd 分支的 sing-box](https://github.com/reF1nd/sing-box-releases)（带 `ebpf` 入站）当作常驻服务跑起来。

**它解决什么**：root 级 eBPF 透明代理常驻运行——开机自启、崩溃自动重启、模块开关就是 sing-box 开关；并且能**劫持热点（网络共享）中其他设备的流量**，这是 SFA 之类非 root 方案做不到的。

## 安装

从 [Releases](https://github.com/lynimbus/sing-box-init/releases) 下载 zip，在 KernelSU Manager 里刷入，重启设备生效。之后的版本更新会出现在 Manager 的模块更新里（自动构建发布）。

## 配置

配置放在 **`/data/adb/sing-box/conf.d/`**，目录下所有 `*.json` 会被合并（数组追加、对象递归合并——**不要在两个文件里定义同 tag 的 inbound/outbound**；目录里非 `.json` 后缀的文件会被忽略）。首次安装会生成一份默认示例配置。

守护进程**不改写你的配置**：接管范围完全由你写在配置里。默认示例只开本机流量，这样一段：

```json
"inbounds": [
  {
    "type": "ebpf",
    "tag": "ebpf-in",
    "local": { "enabled": true },
    "shared": { "enabled": true, "interface": ["wlan0", "rndis0"] }
  }
]
```

（上面同时列了 `shared` 的写法；默认示例里没有 `shared`，没写就是只接管本机。）

- **`local`** — 接管**本机**流量，可用 `include_package` / `exclude_package` / `include_uid` / `exclude_uid` 等做过滤（不写过滤器就是全部本机流量）。
- **`shared`** — 接管**共享出去的下游**流量（Wi-Fi 热点、USB 共享）。`interface` 是必填的下游接口名：热点通常是 `wlan0`（部分机型是 `ap0`/`softap0`），USB 共享是 `rndis0`。⚠️ 列出暂时不存在的接口是安全的，sing-box 会等到它出现；接口成为当前上网出口时会被自动暂停接管。
  ⚠️ **不启用就整块别写**：`"shared": {"enabled": false}` 会被拒绝（`shared options require shared interception`，真机实测）。
- `dns_mode` 默认为 `respect_policy`：先按 uid/包名/来源过滤，再接管目标端口 53。
- `bypass_private_address` 默认 `true`：目标是私有/保留地址（局域网）时不接管。

> ⚠️ 1.14 之后 `ebpf` 入站**不再有 `mode` 字段**（旧的 `mode: local|hybrid` 会被拒绝：`unknown field "mode"`），热点改由 `shared` 平面负责。跨版本抄配置前先对照 `docs/configuration/inbound/ebpf.zh.md`。

改完配置**不用手动重启**：守护进程检测到 `conf.d/` 变化（去抖 0.8 秒）会先跑 `sing-box check` 校验，通过才重启内核；**配置写错不会打断你正在用的网络**，旧内核继续跑，错误会显示在模块描述里。

## 使用

| 操作 | 效果 |
|---|---|
| Manager 里的模块启用/禁用开关 | sing-box 开 / 关（禁用时守护进程仍存活，重新启用会自动拉起） |
| Action 按钮 | 重启 sing-box |
| 模块描述 | 实时状态：运行中 (pid, 核心版本, 崩溃次数) / 启动受阻原因 / 已禁用 |
| WebUI 入口 | 打开 sing-box dashboard（需要在配置里加 `services` 里的 `api` 服务，`listen_port` 如 1235） |

日志在 `/data/adb/sing-box/logs/`（`watchdog.log` 看守护进程、`sing-box.log` 看内核，各超过 1MiB 自动截断）。卸载模块**不会**删除 `/data/adb/sing-box/`，配置会保留。

## 从旧版升级

如果你的版本里还有 `include_package` 纯文本白名单文件：新版本已取消这套机制（改由配置里 `local` 的过滤器决定），刷入新 zip 时该文件会被自动清理，请把包名写进配置。

⚠️ **1.15 核心的 ebpf 入站去掉了 `mode` 字段**：老配置（`"mode": "hybrid"`）在新核心上会直接报 `unknown field "mode"`，需要改写为 `local` / `shared` 两个平面（热点 = `shared`）。

## 构建

```sh
./build.sh          # 交叉编译 aarch64 静态二进制并打包 zip（需要 go + zip）
go test ./...       # 纯逻辑单测
sh test_local.sh    # 本机端到端（stub 内核 + 故障注入）
sh test_device.sh   # 真机故障注入矩阵（需要 adb + 已安装模块）
```

守护进程是纯 Go 标准库实现的单二进制（无第三方依赖），核心代码在 `src/`，设计约束见 [AGENTS.md](AGENTS.md)。
