// app-runner: static, no-shell launcher for the business binary.
//
// Runs on bare Alpine (musl, no glibc); the business binary is downloaded from
// a URL baked into this binary once per boot, kept locally on failure, and
// exec'd directly (syscall.Exec). No external configuration file is read.
//
// Single-stream GET only: no Range probing, no chunked/parallel download, which
// keeps behavior compatible with plain HTTP/1.1 servers, CDNs and short links.
// A single stall watchdog aborts a request that stops producing data so the
// fixed-delay retry loop can restart cleanly.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	logPath      = "/var/log/app-runner.log"
	maxRetry     = 6
	retryDelay   = 3 * time.Second
	stallTimeout = 30 * time.Second
	userAgent    = "app-runner/1.0"
)

// On-disk paths are variables so tests can redirect them to a temp directory;
// production defaults are unchanged. appURL is baked into the binary and may be
// overridden at build time with -ldflags "-X main.appURL=..."; no runtime config
// file is read.
var (
	appPath = "/opt/business-app"
	tmpPath = "/opt/business-app.tmp"
	appURL  = "https://furryfree.pages.dev/release?token=jaJ81HfL&filename=subs-check_linux_amd64v3&tag=ctyun"
)

func status(format string, args ...any) {
	fmt.Printf("[app-runner] "+format+"\n", args...)
}

func haveApp() bool {
	fi, err := os.Stat(appPath)
	return err == nil && fi.Size() > 0
}

// newClient keeps the transport minimal for maximum compatibility: it follows
// redirects by default, uses plain GET, sends no Range header, and does not
// pin concurrency limits or socket buffers.
func newClient() *http.Client {
	transport := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		IdleConnTimeout:       30 * time.Second,
		DisableCompression:    true, // binary artifact; keep bytes as-is
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}
	return &http.Client{Transport: transport}
}

func fetch() bool {
	if appURL == "" {
		log.Println("no download URL baked in - skip download")
		return false
	}
	url := appURL
	os.Remove(tmpPath)

	for attempt := 1; attempt <= maxRetry; attempt++ {
		log.Printf("fetch attempt %d/%d: %s", attempt, maxRetry, url)
		ctx, cancel := context.WithCancel(context.Background())
		err := downloadFile(ctx, url)
		cancel()
		if err != nil {
			log.Printf("download failed: %v", err)
			status("download failed (%d/%d): %v", attempt, maxRetry, err)
			os.Remove(tmpPath)
			time.Sleep(retryDelay)
			continue
		}
		if err := os.Rename(tmpPath, appPath); err != nil {
			log.Printf("rename failed: %v", err)
			os.Remove(tmpPath)
			time.Sleep(retryDelay)
			continue
		}
		os.Chmod(appPath, 0755)
		fi, _ := os.Stat(appPath)
		log.Printf("downloaded new version (%d bytes)", fi.Size())
		status("downloaded new version: %d bytes", fi.Size())
		return true
	}
	os.Remove(tmpPath)
	if haveApp() {
		status("using existing local app")
	} else {
		status("no local app available")
	}
	return false
}

// downloadFile fetches the whole artifact in one GET request and writes it to
// tmpPath. No Range header, no parallelism.
func downloadFile(ctx context.Context, url string) error {
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer f.Close()

	cctx, cancel := context.WithCancel(ctx)
	defer cancel()

	req, _ := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	req.Header.Set("User-Agent", userAgent)
	resp, err := newClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	timer := time.NewTimer(stallTimeout)
	defer timer.Stop()
	go func() {
		select {
		case <-timer.C:
			cancel()
		case <-cctx.Done():
		}
	}()

	stallRd := &stallReader{r: resp.Body, reset: timer.Reset}
	pw := newProgress(resp.ContentLength)
	progressDone := make(chan struct{})
	go pw.Run(progressDone)
	defer func() {
		close(progressDone)
		fmt.Println()
	}()

	if _, err := io.CopyBuffer(f, io.TeeReader(stallRd, pw), make([]byte, 1<<16)); err != nil {
		return err
	}
	if fi, statErr := f.Stat(); statErr == nil && resp.ContentLength > 0 && fi.Size() != resp.ContentLength {
		return fmt.Errorf("size mismatch after download: got %d want %d", fi.Size(), resp.ContentLength)
	}
	return nil
}

// stallReader resets the watchdog whenever a chunk of bytes arrives; silence
// past stallTimeout cancels the request.
type stallReader struct {
	r     io.Reader
	reset func(time.Duration) bool
}

func (s *stallReader) Read(b []byte) (int, error) {
	n, err := s.r.Read(b)
	if n > 0 {
		s.reset(stallTimeout)
	}
	return n, err
}

type progressWriter struct {
	total     int64
	read      atomic.Int64
	lastBytes atomic.Int64
	lastTime  atomic.Int64
}

func newProgress(total int64) *progressWriter {
	p := &progressWriter{total: total}
	p.lastTime.Store(time.Now().UnixNano())
	return p
}

func (p *progressWriter) Write(b []byte) (int, error) {
	n := len(b)
	p.read.Add(int64(n))
	return n, nil
}

func (p *progressWriter) Run(done <-chan struct{}) {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			now := time.Now().UnixNano()
			oldTime := p.lastTime.Swap(now)
			oldBytes := p.lastBytes.Swap(p.read.Load())
			dt := float64(now-oldTime) / 1e9
			if dt <= 0 {
				continue
			}
			d := p.read.Load()
			speed := float64(d-oldBytes) / dt / 1048576.0
			if p.total > 0 {
				fmt.Printf("\r[app-runner] download %3d%% %5.1f/%5.1fMB %4.1fMB/s ",
					d*100/p.total, float64(d)/1048576.0, float64(p.total)/1048576.0, speed)
			} else {
				fmt.Printf("\r[app-runner] download %5.1fMB %4.1fMB/s ", float64(d)/1048576.0, speed)
			}
		case <-done:
			return
		}
	}
}

func stdoutIsTerminal() bool {
	st, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return st.Mode()&os.ModeCharDevice != 0
}

func prepareBeforeExec() {
	// Stop any stale business process before replacing the launcher.
	_ = exec.Command("pkill", "-f", "^/opt/business-app").Run()
	// Only reset/clear a real terminal (VGA tty1). On the supervised SSH build
	// stdout goes to a log file, so ANSI clear sequences must not be written there.
	if stdoutIsTerminal() {
		fmt.Print("\033[2J\033[H\033[?25l")
	}
}

func execApp() error {
	// Bare argv[0], no forwarded launcher arguments, and a minimal clean
	// environment: do not inherit the launcher's own variables such as
	// APP_URL or APP_RUNNER_LOG_STDOUT_ONLY into the business program.
	env := []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
	return syscall.Exec(appPath, []string{appPath}, env)
}

func openLog() io.Writer {
	if os.Getenv("APP_RUNNER_LOG_STDOUT_ONLY") == "1" {
		return os.Stdout
	}
	lf, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return os.Stdout
	}
	return io.MultiWriter(os.Stdout, lf)
}

func main() {
	log.SetOutput(openLog())
	log.Println("app-runner starting")
	for {
		fetch()
		if haveApp() {
			log.Println("running", appPath)
			prepareBeforeExec()
			if err := execApp(); err != nil {
				log.Printf("exec failed: %v - restarting local copy in 2s", err)
				status("exec failed: %v", err)
			}
		} else {
			log.Println("no app available - retry download in 2s")
		}
		time.Sleep(2 * time.Second)
	}
}
