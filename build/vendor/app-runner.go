// app-runner: static, no-shell launcher for the business binary.
//
// Replaces the old shell script. Runs on bare Alpine (musl, no glibc),
// downloaded from APP_URL once per boot, kept locally on failure, exec'd
// directly (syscall.Exec, no Go runtime left behind).
package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"syscall"
	"time"
)

const (
	appPath  = "/opt/business-app"
	tmpPath  = "/opt/business-app.tmp"
	logPath  = "/var/log/app-runner.log"
	maxRetry = 6
)

func line() { fmt.Println("====================================================") }
func banner(msg string) {
	line()
	fmt.Println("  " + msg)
	line()
}

func haveApp() bool {
	fi, err := os.Stat(appPath)
	return err == nil && fi.Size() > 0
}

// fetch downloads APP_URL into a temp file and atomically promotes it.
// On any failure the previous binary is kept.
func fetch() bool {
	url := os.Getenv("APP_URL")
	if url == "" {
		log.Println("APP_URL empty - skip download")
		return false
	}
	os.Remove(tmpPath)

	var lastErr string
	for attempt := 1; attempt <= maxRetry; attempt++ {
		log.Printf("fetch attempt %d/%d: %s", attempt, maxRetry, url)
		if err := downloadOnce(); err != nil {
			lastErr = err.Error()
			log.Printf("download failed: %v", err)
			banner(fmt.Sprintf("更新下载失败 (尝试 %d/%d): %v", attempt, maxRetry, err))
			time.Sleep(3 * time.Second)
			continue
		}
		if err := os.Rename(tmpPath, appPath); err != nil {
			lastErr = err.Error()
			continue
		}
		os.Chmod(appPath, 0755)
		fi, _ := os.Stat(appPath)
		log.Printf("downloaded new version (%d bytes)", fi.Size())
		banner(fmt.Sprintf("更新成功: 新版本 %d 字节", fi.Size()))
		return true
	}
	os.Remove(tmpPath)
	if haveApp() {
		banner("继续使用上一版本")
	} else {
		banner("尚未有可用业务程序")
	}
	_ = lastErr
	return false
}

func downloadOnce() error {
	transport := &http.Transport{
		ForceAttemptHTTP2:     false,
		TLSNextProto:          map[string]func(authority string, c *tls.Conn) http.RoundTripper{},
		MaxIdleConns:          1,
		IdleConnTimeout:       30 * time.Second,
		ReadBufferSize:        262144,
		WriteBufferSize:       262144,
	}
	client := &http.Client{Timeout: 600 * time.Second, Transport: transport}

	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	defer f.Close()

	req, err := http.NewRequest("GET", os.Getenv("APP_URL"), nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "aria2/1.37.0")
	req.Header.Set("Accept", "*/*")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	prog := &progressReader{r: resp.Body, total: resp.ContentLength}
	if _, err := io.CopyBuffer(f, prog, make([]byte, 1<<20)); err != nil {
		return err
	}
	fmt.Println()
	return nil
}

// progressReader prints download progress to stdout (VGA) every 500ms.
type progressReader struct {
	r         io.Reader
	total     int64
	read      int64
	lastPrint time.Time
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.read += int64(n)
	if time.Since(p.lastPrint) > 500*time.Millisecond {
		p.lastPrint = time.Now()
		if p.total > 0 {
			pct := p.read * 100 / p.total
			fmt.Printf("\r  下载中: %d%% (%d/%d MB)   ", pct, p.read/1024/1024, p.total/1024/1024)
		} else {
			fmt.Printf("\r  下载中: %d MB   ", p.read/1024/1024)
		}
	}
	return n, err
}

// execApp replaces the process with the business binary. Only returns on error.
func execApp() error {
	argv := append([]string{appPath}, os.Args[1:]...)
	return syscall.Exec(appPath, argv, os.Environ())
}

func openLog() io.Writer {
	lf, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return os.Stdout
	}
	return io.MultiWriter(os.Stdout, lf)
}

func main() {
	// Load baked-in config (APP_URL etc.) written at image build time.
	if data, err := os.ReadFile("/etc/app-runner.env"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if k, v, ok := strings.Cut(line, "="); ok {
				os.Setenv(strings.TrimSpace(k), strings.TrimSpace(v))
			}
		}
	}
	log.SetOutput(openLog())
	log.Println("app-runner (Go) starting")
	// Every boot: fetch the latest version (keep previous on failure), then run.
	for {
		fetch()
		if haveApp() {
			log.Println("running", appPath)
			if err := execApp(); err != nil {
				log.Printf("exec failed: %v - restarting local copy in 2s", err)
				banner("无法启动业务程序: " + err.Error())
			}
		} else {
			log.Println("no app available - retry download in 2s")
		}
		time.Sleep(2 * time.Second)
	}
}
