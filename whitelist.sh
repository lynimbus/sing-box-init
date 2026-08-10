#!/system/bin/sh
# whitelist.sh — 应用白名单生成 (daemon.sh 内部调用, 不面向用户)
#
# 用法: whitelist.sh <src_dir> <dst_dir> <package_file>
#   src_dir     — sing-box 配置目录 (conf.d)
#   dst_dir     — 生成目录, 写入注入白名单后的配置副本 (每次启动重建)
#   package_file— 白名单包名文件 (纯文本, 每行一个包名, 空行/# 注释忽略)
#
# 流程:
#   1. 总是先把 src 下所有 json 复制到 dst (保证 dst 永远可用)
#   2. package_file 不存在或为空 → 到此为止 (无白名单 = 全部流量走代理)
#   3. src 中存在 ebpf 入站 → 对 dst 中每个文件跑 whitelist.awk,
#      把 include_package 白名单写入每个 ebpf 入站 (替换已有值或插入)
#   4. 否则 (非 ebpf, 如 tun) → 写路由规则文件 00-include-package.json
#      (package_name 白名单 + action: route, 即列出的应用走 final 代理)
#
# 失败返回 1 (daemon.sh 回退用原始 conf.d); 成功返回 0
# 纯 POSIX sh; awk 用 whitelist.awk (兼容 BusyBox awk)

MODDIR=$(cd "${0%/*}" && pwd)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/sing-box-init

SRC=$1
DST=$2
PKGFILE=$3
AWKFILE="$MODDIR/whitelist.awk"

[ -d "$SRC" ] || exit 0
[ -f "$AWKFILE" ] || exit 1

mkdir -p "$DST" || exit 1
rm -f "$DST"/*.json "$DST"/.packages 2>/dev/null

# 1. 复制全部配置文件
for f in "$SRC"/*.json; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DST/" 2>/dev/null
done

# 2. 白名单开关: include_package 被改名成 include_package.disable → 关闭白名单, 正常加载配置 (仅副本)
#    两者都存在时以 include_package 为准 (改名回来即重新启用); 都没有也等同关闭
[ -f "$PKGFILE" ] || exit 0

# 过滤空行与 # 注释, 去掉首尾空白与 \r (兼容 Windows 换行)
grep -v '^[[:space:]]*#' "$PKGFILE" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | tr -d '\r' \
    | sed 's/^[ \t]*//; s/[ \t]*$//' > "$DST/.packages"
[ -s "$DST/.packages" ] || { rm -f "$DST/.packages"; exit 0; }

# 3/4. 检测 src 中是否有 ebpf 入站
if grep -lq '"type"[[:space:]]*:[[:space:]]*"ebpf"' "$SRC"/*.json 2>/dev/null; then
    # ebpf 入站: 注入 include_package
    for f in "$DST"/*.json; do
        [ -f "$f" ] || continue
        bn=${f##*/}
        if ! awk -f "$AWKFILE" -v OUT="$DST/.tmp" -v IP_FILE="$DST/.packages" "$f"; then
            rm -f "$DST/.tmp"
            continue    # awk 异常: 保留原样副本, 由 sing-box 报真实错误
        fi
        mv -f "$DST/.tmp" "$f" 2>/dev/null
    done
else
    # 非 ebpf: 路由规则白名单 (列出的应用走 final), 文件名 00- 前缀 → 合并时规则排最前
    {
        echo '{'
        echo '  "route": {'
        echo '    "rules": ['
        echo '      {'
        echo '        "package_name": ['
        first=1
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            esc=$(printf '%s' "$pkg" | sed 's/\\/\\\\/g; s/"/\\"/g')
            if [ "$first" = 1 ]; then
                printf '          "%s"' "$esc"
                first=0
            else
                printf ',\n          "%s"' "$esc"
            fi
        done < "$DST/.packages"
        printf '\n'
        echo '        ],'
        echo '        "action": "route"'
        echo '      }'
        echo '    ]'
        echo '  }'
        echo '}'
    } > "$DST/00-include-package.json"
fi

rm -f "$DST/.packages"
exit 0
