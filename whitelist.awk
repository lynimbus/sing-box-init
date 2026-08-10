# whitelist.awk — 单文件注入器: 把 include_package 白名单写入 JSON 中每个 ebpf 入站
#
# 用法: awk -f whitelist.awk -v OUT=输出文件 -v IP_FILE=包名列表 < 输入json
#   OUT     — 输出文件路径 (写入注入后的 JSON; 无 ebpf 入站时内容不变)
#   IP_FILE — 白名单包名文件 (一行一个包名, 空行忽略)
#
# 行为 (对每个 "type" 为 "ebpf" 的入站对象):
#   * 对象内已有 include_package 键 → 其值 (数组/字符串) 整体替换为白名单
#   * 没有 → 在对象闭合前插入 "include_package": [白名单] (自动处理逗号与缩进)
# 文件无法解析 (括号不平衡/未闭合字符串) → 原样复制到 OUT, 交由 sing-box 报真实错误
# 纯 POSIX awk (兼容 BusyBox awk): 不使用 gawk 扩展 (ENDFILE 等)

function hexval(ch) {
    if (ch ~ /[0-9]/) return ch - 48
    if (ch ~ /[a-f]/) return index("abcdef", ch) + 9
    if (ch ~ /[A-F]/) return index("ABCDEF", ch) + 9
    return 0
}

# JSON 字符串解转义
function unescape(str,    out, i, n, c, e, cp, h, j) {
    out = ""
    i = 1
    n = length(str)
    while (i <= n) {
        c = substr(str, i, 1)
        if (c == "\\") {
            e = substr(str, i + 1, 1)
            if (e == "u") {
                h = substr(str, i + 2, 4)
                cp = 0
                for (j = 1; j <= 4; j++) cp = cp * 16 + hexval(substr(h, j, 1))
                if (cp < 128) out = out sprintf("%c", cp)
                else if (cp < 2048) out = out sprintf("%c%c", 192 + int(cp / 64), 128 + (cp % 64))
                else out = out sprintf("%c%c%c", 224 + int(cp / 4096), 128 + (int(cp / 64) % 64), 128 + (cp % 64))
                i += 6
            } else if (e == "n") { out = out "\n"; i += 2 }
            else if (e == "t") { out = out "\t"; i += 2 }
            else if (e == "r") { out = out "\r"; i += 2 }
            else if (e == "b") { out = out "\b"; i += 2 }
            else if (e == "f") { out = out "\f"; i += 2 }
            else { out = out e; i += 2 }
        } else {
            out = out c
            i++
        }
    }
    return out
}

# 字符串转义 (写回 JSON 时用)
function jescape(str,    out, i, n, c) {
    out = ""
    i = 1
    n = length(str)
    while (i <= n) {
        c = substr(str, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else out = out c
        i++
    }
    return out
}

# 生成插入文本: 在对象闭合 '}' 前插入 include_package 键
# 替换掉 '}' 前的空白段 (含换行), 让逗号紧贴上一条, 缩进对齐闭合行
# 结果经全局变量 ins_start/ins_end 返回 (编辑区间 = 空白段)
function make_insert(close_pos,    k, ch, indent, keyind, lead) {
    # 闭合行的缩进 (仅空格/tab, 遇到换行或其它字符停止)
    k = close_pos - 1
    indent = ""
    while (k >= 1) {
        ch = substr(s, k, 1)
        if (ch == " " || ch == "\t") { indent = ch indent; k-- }
        else break
    }
    # 闭合前最后一个非空白字符: 决定是否需要补逗号 (空对象 "{" 也不用逗号)
    k = close_pos - 1
    while (k >= 1 && (substr(s, k, 1) in ws)) k--
    lead = ""
    if (k >= 1 && substr(s, k, 1) != "," && substr(s, k, 1) != "{") lead = ","
    ins_start = k + 1
    ins_end = close_pos - 1
    keyind = indent "  "
    return lead "\n" keyind "\"include_package\": " arr "\n" indent
}

BEGIN {
    # 读取白名单包名 (一行一个)
    n = 0
    while ((getline line < IP_FILE) > 0) {
        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line)
        if (line == "") continue
        pkg[++n] = line
    }
    close(IP_FILE)
    arr = "["
    for (i = 1; i <= n; i++) {
        if (i > 1) arr = arr ", "
        arr = arr "\"" jescape(pkg[i]) "\""
    }
    arr = arr "]"

    ws[" "] = 1; ws["\t"] = 1; ws["\r"] = 1; ws["\n"] = 1

    # 读入整个输入
    s = ""
    while ((getline line) > 0) s = s line "\n"

    depth = 0          # 括号深度 ({ 和 [ 统一计数)
    cur_key = ""       # 当前待解析值的键
    balanced = 1
    ned = 0            # 编辑点个数
    delete estart; delete eend; delete erep
    delete obj_type    # obj_type[d] — 深度 d 处对象的 "type" 值
    delete ip_start    # include_package 值起点 (该对象深度 d)
    delete ip_end      # include_package 值终点 (含闭合括号/引号)
    delete ip_pending  # include_package 值 (数组/对象) 尚未闭合
    delete ip_vdepth   # include_package 值的最外层容器深度

    n = length(s)
    i = 1
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") {
            # 解析字符串字面量
            j = i + 1
            raw = ""
            closed = 0
            while (j <= n) {
                cj = substr(s, j, 1)
                if (cj == "\\") { raw = raw substr(s, j, 2); j += 2; continue }
                if (cj == "\"") { closed = 1; break }
                raw = raw cj
                j++
            }
            if (!closed) { balanced = 0; break }   # 未闭合字符串: 非法
            # 跳过闭合引号后的空白
            k = j + 1
            while (k <= n && (substr(s, k, 1) in ws)) k++
            nxt = (k <= n) ? substr(s, k, 1) : ""
            if (nxt == ":") {
                # 键
                cur_key = unescape(raw)
                i = k + 1        # 跳过冒号, 值由主循环处理
                continue
            }
            # 值字符串
            val = unescape(raw)
            if (cur_key != "" && depth >= 1) {
                if (cur_key == "type") {
                    obj_type[depth] = val
                } else if (cur_key == "include_package") {
                    # 字符串值: 起点 = 开引号, 终点 = 闭引号
                    ip_start[depth] = i
                    ip_end[depth] = j
                }
            }
            cur_key = ""
            i = j + 1
            continue
        }
        if (c == "{" || c == "[") {
            if (cur_key == "include_package" && depth >= 1) {
                # 数组/对象值: 起点 = 开括号, 终点 = 最外层闭合括号 (ip_vdepth 记录)
                ip_start[depth] = i
                ip_pending[depth] = 1
                ip_vdepth[depth] = depth + 1
            }
            cur_key = ""
            depth++
            if (c == "{") obj_type[depth] = ""
            i++
            continue
        }
        if (c == "}" || c == "]") {
            if (depth > 0) {
                # include_package 值的最外层容器闭合 → 记录终点
                if (ip_pending[depth - 1] == 1 && ip_vdepth[depth - 1] == depth) {
                    ip_end[depth - 1] = i
                    ip_pending[depth - 1] = 0
                }
                if (c == "}") {
                    d = depth
                    if (obj_type[d] == "ebpf") {
                        ned++
                        if (ip_end[d] > 0) {
                            # 替换已有 include_package 值 (起点..终点含闭合括号/引号)
                            estart[ned] = ip_start[d]
                            eend[ned] = ip_end[d]
                            erep[ned] = arr
                        } else {
                            # 对象闭合前插入: 替换 '}' 前的空白段 (可空), 自动补逗号/缩进
                            erep[ned] = make_insert(i)
                            estart[ned] = ins_start
                            eend[ned] = ins_end
                        }
                    }
                    obj_type[d] = ""
                    ip_start[d] = 0; ip_end[d] = 0; ip_pending[d] = 0; ip_vdepth[d] = 0
                }
                depth--
            } else {
                balanced = 0
                break
            }
            cur_key = ""
            i++
            continue
        }
        if (c == ",") cur_key = ""
        i++
    }
    if (depth != 0) balanced = 0

    if (!balanced) {
        # 无法解析: 原样复制, 让 sing-box 报真实错误
        printf "%s", s > OUT
        exit 0
    }

    # 编辑点按位置排序 (插入排序, 数量很小)
    for (a = 2; a <= ned; a++) {
        ks = estart[a]; ke = eend[a]; kr = erep[a]
        b = a - 1
        while (b >= 1 && estart[b] > ks) {
            estart[b + 1] = estart[b]
            eend[b + 1] = eend[b]
            erep[b + 1] = erep[b]
            b--
        }
        estart[b + 1] = ks; eend[b + 1] = ke; erep[b + 1] = kr
    }

    # 拼接输出: 编辑点处替换 (区间可空 = 插入), 其余字节原样保留
    out = ""
    pos = 1
    for (e = 1; e <= ned; e++) {
        if (estart[e] > pos) out = out substr(s, pos, estart[e] - pos)
        out = out erep[e]
        pos = eend[e] + 1
    }
    if (pos <= n) out = out substr(s, pos)
    printf "%s", out > OUT
    exit 0
}
