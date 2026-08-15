#!/system/bin/sh
# sing-box-init 安装脚本
# 由模块安装器 (KernelSU/Magisk) source 执行, 提供 ui_print/abort/set_perm 函数
# 用途: 从 bin/ 中的 tar.gz 解压出 sing-box 可执行文件, 并初始化持久化配置目录

ui_print "[sing-box-init] 开始安装..."

# 架构检查: 随模块附带的安装包为 android-arm64
if [ -n "$ARCH" ] && [ "$ARCH" != "arm64" ]; then
    ui_print "[sing-box-init] 错误: 仅支持 arm64 架构, 当前设备为 $ARCH"
    abort "sing-box-init: 不支持的架构"
fi

# 从 bin/ 中的 tar.gz 解压出 sing-box 可执行文件到模块的 bin/ 目录
ARCHIVE=$(ls "$MODPATH"/bin/sing-box-*.tar.gz 2>/dev/null | head -n 1)
if [ -z "$ARCHIVE" ]; then
    abort "sing-box-init: 未在模块 bin/ 目录找到 sing-box 安装包"
fi
ui_print "[sing-box-init] 解压 $(basename "$ARCHIVE") ..."
tar -xzf "$ARCHIVE" -C "$MODPATH" || abort "sing-box-init: 解压安装包失败"

BIN_SRC=$(ls -d "$MODPATH"/sing-box-*/sing-box 2>/dev/null | head -n 1)
if [ -z "$BIN_SRC" ]; then
    abort "sing-box-init: 安装包内容无效 (未找到 sing-box 可执行文件)"
fi

mkdir -p "$MODPATH/bin"
mv -f "$BIN_SRC" "$MODPATH/bin/sing-box"
rm -rf "$MODPATH"/sing-box-*
rm -f "$ARCHIVE"
set_perm "$MODPATH/bin/sing-box" 0 0 0755
ui_print "[sing-box-init] sing-box 已安装到 $MODPATH/bin/sing-box"

# Zig 守护进程二进制: zip 解压可能丢 +x, 必须显式设权限
# (daemon.sh 是 sh 包装经 sh 调用, 不依赖可执行位; 二进制本身需要)
set_perm "$MODPATH/bin/sing-box-init" 0 0 0755

# 确保脚本可执行 (安装器解压出的 zip 权限可能不含 +x)
chmod 0755 "$MODPATH"/*.sh 2>/dev/null

# 初始化配置目录 (配置持久化在 /data/adb/sing-box, 不受模块更新/卸载影响)
# 布局: conf.d/ 为 sing-box 配置目录 (-C 模式), 目录内 json 全部合并 (数组追加, 勿重复定义同 tag 的 inbound/outbound)
#       默认示例配置 config.json 为 tun 全局代理, 加应用只改 include_package 纯文本文件
DATA_DIR=/data/adb/sing-box
mkdir -p "$DATA_DIR" "$DATA_DIR/logs" "$DATA_DIR/conf.d"

# 旧版 ebpf 入站文件清理: 本版本已彻底移除 ebpf 支持 (默认改为 tun 全局代理),
# 遗留的 bypass-apps.json 必然含 ebpf 入站, 保留会导致 sing-box 启动失败, 直接移除
if [ -f "$DATA_DIR/conf.d/bypass-apps.json" ]; then
    rm -f "$DATA_DIR/conf.d/bypass-apps.json"
    ui_print "[sing-box-init] 已移除旧版 bypass-apps.json (ebpf 入站已废弃, 请改用 tun/路由规则)"
fi

if [ ! -f "$DATA_DIR/conf.d/config.json" ]; then
    if [ -f "$DATA_DIR/config.json" ]; then
        cp -f "$DATA_DIR/config.json" "$DATA_DIR/conf.d/config.json"
        ui_print "[sing-box-init] 已迁移已有配置到: $DATA_DIR/conf.d/config.json"
    else
        cp -f "$MODPATH/config/config.json" "$DATA_DIR/conf.d/config.json"
        ui_print "[sing-box-init] 已生成默认配置: $DATA_DIR/conf.d/config.json"
    fi
else
    ui_print "[sing-box-init] 检测到已有配置, 保留: $DATA_DIR/conf.d/config.json"
fi

# 应用白名单文件 (纯文本, 每行一个包名 = 走代理的应用; 空行/# 注释忽略), 仅不存在时复制, 不覆盖用户改动
# daemon.sh 启动时读取白名单并生成路由规则 (package_name + action: route, 列出的应用走代理)
# 若用户已把 include_package 改名成 include_package.disable (关闭白名单), 更新/重装模块时也不重新生成, 保持禁用状态
if [ ! -f "$DATA_DIR/include_package" ] && [ ! -f "$DATA_DIR/include_package.disable" ]; then
    cp -f "$MODPATH/config/include_package" "$DATA_DIR/include_package"
    ui_print "[sing-box-init] 已生成应用白名单: $DATA_DIR/include_package"
fi

ui_print "[sing-box-init] 安装完成, 重启后自动生效"
