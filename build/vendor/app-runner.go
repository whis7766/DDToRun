// app-runner: static, no-shell launcher for the business binary.
//
// Runs on bare Alpine (musl, no glibc), downloaded from APP_URL once per boot,
// kept locally on failure, exec'd directly (syscall.Exec).
//
// If the server supports HTTP Range, downloads in 4 parallel chunks; otherwise
// falls back to a single stream with stall detection.
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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	appPath      = "/opt/business-app"
	tmpPath      = "/opt/business-app.tmp"
	logPath      = "/var/log/app-runner.log"
	maxRetry     = 6
	numWorkers   = 4
	stallTimeout = 30 * time.Second
)

func status(format string, args ...any) {
	fmt.Printf("[app-runner] "+format+"\n", args...)
}

func haveApp() bool {
	fi, err := os.Stat(appPath)
	return err == nil && fi.Size() > 0
}

func newClient() *http.Client {
	dialer := &net.Dialer{
		Timeout:   15 * time.Second,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			// TCP_NODELAY + explicit socket buffers (kernel autotune may be
			// conservative on a fresh Alpine with no sysctl tuning).
			return c.Control(func(fd uintptr) {
				syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_NODELAY, 1)
				syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 4<<20)
				syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_SNDBUF, 4<<20)
			})
		},
	}
	transport := &http.Transport{
		MaxIdleConns:          numWorkers,
		MaxConnsPerHost:       numWorkers,
		IdleConnTimeout:       30 * time.Second,
		DialContext:           dialer.DialContext,
		ReadBufferSize:        4 << 20,
		WriteBufferSize:       4 << 20,
		TLSHandshakeTimeout:   10 * time.Second,
		DisableCompression:    true, // binary, no gzip
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
		// TLSNextProto left nil -> Go auto-negotiates h2 when the server
		// supports it (ALPN "h2"), falls back to http/1.1 otherwise.
	}
	// No client.Timeout: never abort an in-progress download as a whole.
	// Only the stall watchdog (30s without data) triggers a retry.
	return &http.Client{Transport: transport}
}

func fetch() bool {
	url := os.Getenv("APP_URL")
	if url == "" {
		log.Println("APP_URL empty - skip download")
		return false
	}
	os.Remove(tmpPath)

	for attempt := 1; attempt <= maxRetry; attempt++ {
		log.Printf("fetch attempt %d/%d: %s", attempt, maxRetry, url)
		if err := downloadOnce(url); err != nil {
			log.Printf("download failed: %v", err)
			status("download failed (%d/%d): %v", attempt, maxRetry, err)
			time.Sleep(3 * time.Second)
			continue
		}
		if err := os.Rename(tmpPath, appPath); err != nil {
			log.Printf("rename failed: %v", err)
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

func downloadOnce(url string) error {
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	defer f.Close()

	client := newClient()

	// Probe: ask for the first byte to check Range support + total size.
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "aria2/1.37.0")
	req.Header.Set("Range", "bytes=0-0")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	total := int64(-1)
	supportsRange := resp.StatusCode == http.StatusPartialContent
	if supportsRange {
		if cr := resp.Header.Get("Content-Range"); cr != "" {
			if idx := strings.LastIndex(cr, "/"); idx >= 0 {
				if n, perr := strconv.ParseInt(cr[idx+1:], 10, 64); perr == nil {
					total = n
				}
			}
		}
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	if supportsRange && total > 65536 {
		return downloadParallel(client, f, url, total)
	}
	return downloadSingle(client, f, url)
}

// downloadSingle downloads the whole body in one stream with stall detection.
func downloadSingle(client *http.Client, f *os.File, url string) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "aria2/1.37.0")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	// Stall watchdog: if no bytes for stallTimeout, abort so we can retry.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.NewTimer(stallTimeout)
	defer timer.Stop()
	go func() {
		select {
		case <-timer.C:
			cancel()
		case <-ctx.Done():
		}
	}()

	stallRd := &stallReader{r: resp.Body, reset: timer.Reset}
	pw := newProgress(resp.ContentLength)
	progressDone := make(chan struct{})
	go pw.Run(progressDone)
	_, err = io.CopyBuffer(f, io.TeeReader(stallRd, pw), make([]byte, 1<<20))
	close(progressDone)
	fmt.Println()
	if err != nil {
		return err
	}
	if fi, statErr := f.Stat(); statErr == nil && resp.ContentLength > 0 && fi.Size() != resp.ContentLength {
		return fmt.Errorf("size mismatch after download: got %d want %d", fi.Size(), resp.ContentLength)
	}
	return nil
}

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

func downloadParallel(client *http.Client, f *os.File, url string, total int64) error {
	var downloaded atomic.Int64
	var wg sync.WaitGroup
	errCh := make(chan error, numWorkers)
	chunk := total / int64(numWorkers)

	for i := 0; i < numWorkers; i++ {
		start := int64(i) * chunk
		end := total - 1
		if i < numWorkers-1 {
			end = start + chunk - 1
		}
		wg.Add(1)
		go func(start, end int64) {
			defer wg.Done()
			if e := fetchChunk(client, f, url, start, end, &downloaded); e != nil {
				errCh <- e
			}
		}(start, end)
	}

	// Progress printer with transfer speed
	done := make(chan struct{})
	var lastBytes atomic.Int64
	lastTime := time.Now()
	go func() {
		t := time.NewTicker(500 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				now := time.Now()
				d := downloaded.Load()
				old := lastBytes.Swap(d)
				speed := float64(d-old) / now.Sub(lastTime).Seconds() / 1048576.0
				lastTime = now
				if total > 0 {
					fmt.Printf("\r[app-runner] download %3d%% %5.1f/%5.1fMB %4.1fMB/s ",
						d*100/total, float64(d)/1048576.0, float64(total)/1048576.0, speed)
				}
			case <-done:
				return
			}
		}
	}()

	wg.Wait()
	if fi, statErr := f.Stat(); statErr == nil && fi.Size() != total {
		return fmt.Errorf("size mismatch after parallel download: got %d want %d", fi.Size(), total)
	} else if statErr != nil {
		return statErr
	}
	close(done)
	fmt.Println()

	select {
	case e := <-errCh:
		return e
	default:
		return nil
	}
}

func fetchChunk(client *http.Client, f *os.File, url string, start, end int64, downloaded *atomic.Int64) error {
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		req, _ := http.NewRequest("GET", url, nil)
		req.Header.Set("User-Agent", "aria2/1.37.0")
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		if resp.StatusCode != http.StatusPartialContent {
			resp.Body.Close()
			lastErr = fmt.Errorf("HTTP %d", resp.StatusCode)
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		buf := make([]byte, 1<<20)
		_, err = copyAt(f, resp.Body, start, buf, downloaded)
		resp.Body.Close()
		if err == nil {
			return nil
		}
		lastErr = err
		time.Sleep(time.Duration(attempt) * time.Second)
	}
	return lastErr
}

func copyAt(f *os.File, r io.Reader, off int64, buf []byte, downloaded *atomic.Int64) (int64, error) {
	total := int64(0)
	for {
		nr, er := r.Read(buf)
		if nr > 0 {
			nw, ew := f.WriteAt(buf[0:nr], off)
			downloaded.Add(int64(nw))
			off += int64(nw)
			total += int64(nw)
			if ew != nil {
				return total, ew
			}
		}
		if er == io.EOF {
			break
		}
		if er != nil {
			return total, er
		}
	}
	return total, nil
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

func prepareBeforeExec() {
	// Stop any stale business process before replacing the launcher.
	_ = exec.Command("pkill", "-f", "^/opt/business-app").Run()
	// Reset and clear the foreground terminal before the app takes over.
	fmt.Print("\033[2J\033[H\033[?25l")
}

func execApp() error {
	argv := append([]string{appPath}, os.Args[1:]...)
	return syscall.Exec(appPath, argv, os.Environ())
}

func openLog() io.Writer {
	if os.Getenv("APP_RUNNER_LOG_STDOUT_ONLY") == "1" {
		return os.Stdout
	}
	lf, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return os.Stdout
	}
	return io.MultiWriter(os.Stdout, lf)
}

func main() {
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
