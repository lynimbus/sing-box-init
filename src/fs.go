package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func ensureDir(p string) {
	_ = os.MkdirAll(p, 0o755)
}

func removeFile(p string) {
	_ = os.Remove(p)
}

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

func writeFile(p string, s string) {
	_ = os.WriteFile(p, []byte(s), 0o644)
}

func appendFile(p string, s string) {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(s)
	_ = f.Close()
}

func truncateIfLarger(p string, max int64) {
	st, err := os.Stat(p)
	if err != nil || st.Size() <= max {
		return
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return
	}
	_ = f.Close()
}

// rotateLog 把当前日志归档为 path.1, 旧代依次后移, 只保留 keep 代 (含当前日志)。
// 只能在没有进程持有该日志 fd 时调用: 内核长驻时 fd 绑在 inode 上, rename 对它无效,
// 所以轮转只能趁内核刚退出、下一个内核还没起来的空档做。
func rotateLog(path string, keep int) {
	st, err := os.Stat(path)
	if err != nil {
		return
	}
	if st.Size() == 0 {
		removeFile(path)
		return
	}
	if keep < 2 {
		removeFile(path)
		return
	}
	removeFile(rotatedLogPath(path, keep-1))
	for gen := keep - 2; gen >= 1; gen-- {
		if fileExists(rotatedLogPath(path, gen)) {
			_ = os.Rename(rotatedLogPath(path, gen), rotatedLogPath(path, gen+1))
		}
	}
	_ = os.Rename(path, rotatedLogPath(path, 1))
}

func rotatedLogPath(path string, gen int) string {
	return fmt.Sprintf("%s.%d", path, gen)
}

func readPidFile(p string) int {
	s := strings.TrimSpace(readFile(p))
	if s == "" {
		return -1
	}
	v, err := strconv.Atoi(s)
	if err != nil || v <= 0 {
		return -1
	}
	return v
}

func configFiles(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		out = append(out, filepath.Join(dir, e.Name()))
	}
	return out
}

type fileSig struct {
	name  string
	size  int64
	mtime int64
}

// confScanner 是配置目录内容的权威指纹计算器: 任何增删改都会改变指纹。
// 热重载靠它判断, 不依赖 inotify 事件是否送达。
// 看门狗每 tick 调用一次, 所以把排序、格式化、拼接的分配全部跨 tick 复用;
// readdir + 每文件一次 lstat 是信息本身要求的系统调用, 无法省。
// 未变化时连结果字符串都不分配: Builder.String() 是内部缓冲的零拷贝视图,
// 与上次克隆比较相等就直接返回旧串 —— 因此返回值与内部缓冲永不别名。
type confScanner struct {
	ents  []fileSig
	num   []byte
	b     strings.Builder
	last  string
	valid bool
}

func (cs *confScanner) fingerprint(dir string) string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return "unreadable"
	}
	sigs := cs.ents[:0]
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		sigs = append(sigs, fileSig{e.Name(), info.Size(), info.ModTime().UnixNano()})
	}
	cs.ents = sigs
	// 配置目录只有个位数文件, 插入排序避免 sort.Slice 的闭包与 swapper 分配
	for i := 1; i < len(sigs); i++ {
		s := sigs[i]
		j := i - 1
		for j >= 0 && sigs[j].name > s.name {
			sigs[j+1] = sigs[j]
			j--
		}
		sigs[j+1] = s
	}
	cs.b.Reset()
	for i, s := range sigs {
		if i > 0 {
			cs.b.WriteByte('|')
		}
		cs.b.WriteString(s.name)
		cs.b.WriteByte(':')
		cs.num = strconv.AppendInt(cs.num[:0], s.size, 10)
		cs.b.Write(cs.num)
		cs.b.WriteByte(':')
		cs.num = strconv.AppendInt(cs.num[:0], s.mtime, 10)
		cs.b.Write(cs.num)
	}
	if cs.valid && cs.b.String() == cs.last {
		return cs.last
	}
	cs.last = strings.Clone(cs.b.String())
	cs.valid = true
	return cs.last
}

// confFingerprint 一次性求指纹 (初始化与测试用); 热路径走 confScanner。
func confFingerprint(dir string) string {
	var cs confScanner
	return cs.fingerprint(dir)
}

func waitExit(pid int, d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}
