package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

const (
	sigTERM = syscall.SIGTERM
	sigKILL = syscall.SIGKILL
)

type child struct {
	cmd  *exec.Cmd
	pid  int
	done chan struct{}
	err  error
}

func startChild(bin string, args []string, dir string, logPath string) (*child, error) {
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	cmd.Stdin = nil
	cmd.Stdout = f
	cmd.Stderr = f
	if err := cmd.Start(); err != nil {
		_ = f.Close()
		return nil, err
	}
	_ = f.Close()
	c := &child{cmd: cmd, pid: cmd.Process.Pid, done: make(chan struct{})}
	go func() {
		defer func() {
			if r := recover(); r != nil {
				c.err = fmt.Errorf("wait panic: %v", r)
			}
			close(c.done)
		}()
		c.err = cmd.Wait()
	}()
	return c, nil
}

func (c *child) exited() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

func (c *child) alive() bool {
	return !c.exited() && processAlive(c.pid)
}

func (c *child) term() {
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Signal(syscall.SIGTERM)
	}
}

func (c *child) kill() {
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
}

func spawnDetached(exe string, args []string, logPath string) (int, error) {
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	cmd := exec.Command(exe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin = nil
	cmd.Stdout = f
	cmd.Stderr = f
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	pid := cmd.Process.Pid
	_ = cmd.Process.Release()
	return pid, nil
}

func selfExe() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	st, ok := processState(pid)
	return ok && st != 'Z'
}

func processState(pid int) (byte, bool) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, false
	}
	i := bytes.LastIndexByte(b, ')')
	if i < 0 || i+2 >= len(b) {
		return 0, false
	}
	return b[i+2], true
}

func processExe(pid int) string {
	p, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func processArgv(pid int) []string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil
	}
	var out []string
	for _, part := range bytes.Split(b, []byte{0}) {
		if len(part) == 0 {
			continue
		}
		out = append(out, string(part))
	}
	return out
}

// ownsProcess 严格判断 pid 是否由 exe 启动的进程(逐字段精确比对, 不做子串猜测)。
// 不能用 "cmdline 含 sing-box": 看门狗自己的 argv 是 sing-box-init, 也会命中。
// 脚本内核的 argv[0] 是解释器, 脚本路径在 argv[1], 所以两种形态都认。
func ownsProcess(pid int, exe string) bool {
	if !processAlive(pid) {
		return false
	}
	want := exe
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		want = r
	}
	if got := processExe(pid); got != "" && got == want {
		return true
	}
	argv := processArgv(pid)
	if len(argv) > 0 && argv[0] == exe {
		return true
	}
	return len(argv) > 1 && argv[1] == exe
}

func signalPID(pid int, sig syscall.Signal) {
	if pid > 0 {
		_ = syscall.Kill(pid, sig)
	}
}

func runWithTimeout(timeout time.Duration, dir string, bin string, args ...string) ([]byte, error) {
	cmd := exec.Command(bin, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return buf.Bytes(), err
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		return buf.Bytes(), fmt.Errorf("超时 (%s)", timeout)
	}
}
