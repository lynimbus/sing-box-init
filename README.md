# sing-box init

KernelSU / Magisk 模块：把[官方 sing-box](https://github.com/SagerNet/sing-box)（上游 SagerNet）当作常驻服务跑起来。

**它解决什么**：root 级透明代理常驻运行——开机自启、崩溃自动重启、模块开关就是 sing-box 开关；`tun` 入站的 `auto_redirect` 能**劫持热点（网络共享）中其他设备的流量**，这是 SFA 之类非 root 方案做不到的。

> 本仓库两个书签：`main` 跟 [reF1nd 分支核心](https://github.com/reF1nd/sing-box-releases)（带 `ebpf` 入站），`official`（本分支）跟官方核心、用 `tun` + `auto_redirect`。两边安装包不通用，各自的 `updateJson` 指向自己的分支。

## 安装

从 [Releases](https://github.com/lynimbus/sing-box-init/releases) 下载 zip，在 KernelSU Manager 里刷入，重启设备生效。之后的版本更新会出现在 Manager 的模块更新里（自动构建发布）。

## 配置

配置放在 **`/data/adb/sing-box/conf.d/`**，目录下所有 `*.json` 会被合并（数组追加、对象递归合并——**不要在两个文件里定义同 tag 的 inbound/outbound**；目录里非 `.json` 后缀的文件会被忽略）。首次安装会生成一份默认示例配置。

守护进程**不改写你的配置**：接管范围完全由你写在配置里。默认示例就是这一段（tun 接管全机 + 热点，出站全直连）：

```json
"inbounds": [
  {
    "type": "tun",
    "tag": "tun-in",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "mtu": 9000,
    "auto_route": true,
    "auto_redirect": true,
    "dns_mode": "disabled"
  }
],
"route": { "auto_detect_interface": true }
```

- **`auto_route` + `auto_redirect`** — 前者把默认路由指到 tun，后者用 nftables 把流量重定向进来。两个一起才能接管**本机**流量和**共享出去的下游**流量（Wi-Fi 热点、USB 共享、中继）；上游文档写明 `auto_redirect` 在 Android root 下受支持、含转发流量。`auto_redirect` 依赖 `auto_route`，单独写不生效。
- **`route.auto_detect_interface: true`** — 别省。否则出站回落时会再次撞进 tun，形成回环。
- **`dns_mode: "disabled"`** — 开 `auto_route` 时它默认就是 `hijack`（抢下 53 端口交给核心自己的 DNS）。这个模板的出站只有 `direct`，抢 DNS 没有收益；而没配 `dns.servers`、系统 DNS 又指向 tun 时会绕成环，表现就是"装完没网"。要接管 DNS 就自己补 `dns` 块，再把这一行删掉。
- 分应用过滤写在 tun 入站的 **`include_package` / `exclude_package` / `include_uid` / `exclude_uid`**（不写就是全部本机流量）。别用 `route.rules[].package_name` 做这件事，它依赖进程可见性、部分构建下不生效。

> ⚠️ 官方核心**没有 `ebpf` 入站**（那是 reF1nd 分支的特性，`main` 书签在用）。从 `main` 抄来的 `"type": "ebpf"` 在这边会让 `sing-box check` 直接失败。
> 排障：`su -c 'ip link show'` 看 tun 设备、`su -c 'nft list ruleset | grep -i sing'` 看重定向规则、`su -c 'ip route show table 2022'` 看 auto_route 是否铺上。

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
