package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	logMaxBytes    = 1024 * 1024
	defaultModDir  = "/data/adb/modules/sing-box-init"
	defaultDataDir = "/data/adb/sing-box"
)

type app struct {
	modDir  string
	dataDir string

	bin         string
	confDir     string
	logDir      string
	watchdogLog string
	singboxLog  string

	pidFile   string
	wpidFile  string
	stopFlag  string
	lockFile  string
	stateFile string

	moduleProp  string
	disableFlag string
	removeFlag  string
}

func newApp() *app {
	modDir := resolveModDir()
	dataDir := os.Getenv("SING_BOX_DATA_DIR")
	if dataDir == "" {
		dataDir = defaultDataDir
	}
	a := &app{
		modDir:      modDir,
		dataDir:     dataDir,
		bin:         filepath.Join(modDir, "bin", "sing-box"),
		confDir:     filepath.Join(dataDir, "conf.d"),
		logDir:      filepath.Join(dataDir, "logs"),
		watchdogLog: filepath.Join(dataDir, "logs", "watchdog.log"),
		singboxLog:  filepath.Join(dataDir, "logs", "sing-box.log"),
		pidFile:     filepath.Join(dataDir, "sing-box.pid"),
		wpidFile:    filepath.Join(dataDir, "sing-box-watchdog.pid"),
		stopFlag:    filepath.Join(dataDir, ".stop"),
		lockFile:    filepath.Join(dataDir, ".watchdog.lock"),
		stateFile:   filepath.Join(dataDir, "logs", "watchdog.state"),
		moduleProp:  filepath.Join(modDir, "module.prop"),
		disableFlag: filepath.Join(modDir, "disable"),
		removeFlag:  filepath.Join(modDir, "remove"),
	}
	ensureDir(a.dataDir)
	ensureDir(a.logDir)
	ensureDir(a.confDir)
	return a
}

func resolveModDir() string {
	if self := selfExe(); self != "" {
		dir := filepath.Dir(filepath.Dir(self))
		if fileExists(filepath.Join(dir, "module.prop")) {
			return dir
		}
	}
	return defaultModDir
}

func (a *app) log(level string, format string, args ...any) {
	truncateIfLarger(a.watchdogLog, logMaxBytes)
	line := time.Now().Format("2006-01-02 15:04:05") + " [" + level + "] " + fmt.Sprintf(format, args...) + "\n"
	appendFile(a.watchdogLog, line)
}

func (a *app) moduleDisabled() bool {
	if !dirExists(a.modDir) {
		return true
	}
	return fileExists(a.disableFlag) || fileExists(a.removeFlag)
}

func (a *app) corePid() int {
	pid := readPidFile(a.pidFile)
	if pid > 0 && ownsProcess(pid, a.bin) {
		return pid
	}
	return -1
}

func (a *app) watchdogPid() int {
	pid := readPidFile(a.wpidFile)
	if pid > 0 && ownsProcess(pid, selfExe()) {
		return pid
	}
	return -1
}

type stateInfo struct {
	state   string
	core    string
	crashes int
	reason  string
	updated int64
}

func (a *app) writeState(inf stateInfo) {
	inf.updated = time.Now().Unix()
	var b strings.Builder
	fmt.Fprintf(&b, "state=%s\ncore=%s\ncrashes=%d\nreason=%s\nupdated=%d\n",
		inf.state, inf.core, inf.crashes, oneLine(inf.reason), inf.updated)
	_ = os.WriteFile(a.stateFile, []byte(b.String()), 0o644)
}

func (a *app) readState() stateInfo {
	var inf stateInfo
	for _, line := range strings.Split(readFile(a.stateFile), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "state":
			inf.state = v
		case "core":
			inf.core = v
		case "crashes":
			inf.crashes, _ = strconv.Atoi(v)
		case "reason":
			inf.reason = v
		case "updated":
			inf.updated, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	return inf
}

func (a *app) describe() string {
	inf := a.readState()
	cpid := a.corePid()
	wpid := a.watchdogPid()

	if cpid > 0 {
		desc := fmt.Sprintf("sing-box: 运行中 (pid %d", cpid)
		if inf.core != "" {
			desc += ", core " + inf.core
		}
		if inf.crashes > 0 {
			desc += fmt.Sprintf(", 崩溃 %d 次", inf.crashes)
		}
		desc += ")"
		if wpid <= 0 {
			desc += " [看门狗未运行]"
		}
		if inf.reason != "" {
			desc += " " + truncate(inf.reason, 60)
		}
		return desc
	}
	if a.moduleDisabled() {
		return "sing-box: 未运行 (模块已禁用)"
	}
	if wpid > 0 {
		switch inf.state {
		case "starting":
			return "sing-box: 启动中…"
		case "stopping":
			return "sing-box: 停止中…"
		case "crash_backoff":
			return fmt.Sprintf("sing-box: 崩溃退避中 (第 %d 次)", inf.crashes)
		case "blocked":
			return "sing-box: 未运行 (启动受阻: " + truncate(inf.reason, 60) + ")"
		}
		return "sing-box: 未运行 (看门狗待命)"
	}
	return "sing-box: 未运行"
}

func (a *app) setDescription(desc string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "ksud", "module", "config", "set", "override.description", desc).Run()
	a.rewriteModulePropDesc(desc)
}

// rewriteModulePropDesc 原地改写 description 行。不要改成 "写临时文件再 rename":
// rename 会把 module.prop 的 SELinux context 换成新文件的, Manager 可能因此读不到它。
func (a *app) rewriteModulePropDesc(desc string) {
	data := readFile(a.moduleProp)
	if data == "" {
		return
	}
	lines := strings.Split(strings.TrimRight(data, "\n"), "\n")
	changed := false
	for i, l := range lines {
		if strings.HasPrefix(l, "description=") {
			if l != "description="+desc {
				lines[i] = "description=" + desc
				changed = true
			}
		}
	}
	if !changed {
		return
	}
	writeFile(a.moduleProp, strings.Join(lines, "\n")+"\n")
}

func truncate(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max]) + "…"
}

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.ReplaceAll(s, "=", ":")
}
