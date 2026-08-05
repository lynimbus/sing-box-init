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
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
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

# 确保脚本可执行 (安装器解压出的 zip 权限可能不含 +x)
chmod 0755 "$MODPATH"/*.sh 2>/dev/null

# 初始化配置目录 (配置持久化在 /data/adb/sing-box, 不受模块更新/卸载影响)
# 布局: conf.d/ 为 sing-box 配置目录 (-C 模式), 目录内 json 全部合并, 独立排除文件丢这里即可
DATA_DIR=/data/adb/sing-box
mkdir -p "$DATA_DIR" "$DATA_DIR/logs" "$DATA_DIR/conf.d"
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

# 独立排除文件 (按包名直连, 如 QQ/微信), 仅不存在时复制, 不覆盖用户改动
if [ ! -f "$DATA_DIR/conf.d/bypass-apps.json" ]; then
    cp -f "$MODPATH/config/bypass-apps.json" "$DATA_DIR/conf.d/bypass-apps.json"
    ui_print "[sing-box-init] 已生成排除文件: $DATA_DIR/conf.d/bypass-apps.json"
fi

ui_print "[sing-box-init] 安装完成, 重启后自动生效"
