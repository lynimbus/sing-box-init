package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
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

// confFingerprint 是配置目录内容的权威指纹: 任何增删改都会改变它。
// 热重载靠它判断, 不依赖 inotify 事件是否送达。
func confFingerprint(dir string) string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return "unreadable"
	}
	parts := make([]string, 0, len(ents))
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s:%d:%d", e.Name(), info.Size(), info.ModTime().UnixNano()))
	}
	sort.Strings(parts)
	return strings.Join(parts, "|")
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
