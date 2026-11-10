// app-runner slim: same behavior as app-runner.go but without net/http, so the
// HTTP/2 stack and the net/http transport abstraction are dropped. Only a
// minimal HTTP/1.1 client over crypto/tls is kept: single-stream GET, redirects,
// chunked/content-length bodies, a stall watchdog via read deadlines, fixed
// retries, and a clean syscall.Exec. TLS/cert verification is unchanged.
package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	logPath      = "/var/log/app-runner.log"
	maxRetry     = 6
	maxRedirects = 10
	retryDelay   = 3 * time.Second
	stallTimeout = 30 * time.Second
	userAgent    = "app-runner/1.0"
)

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

// conn is the minimal abstraction over a TCP or TLS stream.
type conn struct {
	raw  net.Conn
	br   *bufio.Reader
	cl   int64 // expected content length (-1 = unknown / read to EOF)
	chunk bool
}

func dial(rawURL string) (*conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	dialer := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	raw, err := dialer.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, err
	}
	var stream net.Conn = raw
	if u.Scheme == "https" {
		tc := tls.Client(raw, &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: host,
		})
		tc.SetDeadline(time.Now().Add(10 * time.Second))
		if err := tc.Handshake(); err != nil {
			raw.Close()
			return nil, err
		}
		tc.SetDeadline(time.Time{})
		stream = tc
	}
	c := &conn{raw: stream, br: bufio.NewReaderSize(stream, 1<<16), cl: -1}

	// Request target: origin-form path (and query). Default to "/".
	target := u.RequestURI()
	if target == "" || target == u.Host {
		target = "/"
	}
	req := "GET " + target + " HTTP/1.1\r\n" +
		"Host: " + u.Host + "\r\n" +
		"User-Agent: " + userAgent + "\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n\r\n"
	if _, err := io.WriteString(stream, req); err != nil {
		raw.Close()
		return nil, err
	}
	return c, nil
}

// readStatus reads and parses the response status line and headers.
func (c *conn) readStatus() (int, string, error) {
	line, err := c.br.ReadString('\n')
	if err != nil {
		return 0, "", err
	}
	parts := strings.Split(strings.TrimSpace(line), " ")
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, "", fmt.Errorf("bad status line: %q", line)
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, "", err
	}
	location := ""
	for {
		h, err := c.br.ReadString('\n')
		if err != nil {
			return 0, "", err
		}
		h = strings.TrimSpace(h)
		if h == "" {
			break
		}
		idx := strings.IndexByte(h, ':')
		if idx < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(h[:idx]))
		val := strings.TrimSpace(h[idx+1:])
		switch key {
		case "content-length":
			if n, err := strconv.ParseInt(val, 10, 64); err == nil {
				c.cl = n
			}
		case "transfer-encoding":
			if strings.Contains(strings.ToLower(val), "chunked") {
				c.chunk = true
				c.cl = -1
			}
		case "location":
			location = val
		}
	}
	return code, location, nil
}

// armWatchdog makes the next read fail if no data arrives for stallTimeout.
func (c *conn) armWatchdog() {
	c.raw.SetReadDeadline(time.Now().Add(stallTimeout))
}

// bodyReader returns the io.Reader for the response body, transparently
// decoding chunked transfer encoding.
func (c *conn) bodyReader() io.Reader {
	if c.chunk {
		return &chunkedReader{br: c.br, c: c}
	}
	if c.cl >= 0 {
		return io.LimitReader(c.br, c.cl)
	}
	return c.br // Connection: close -> read until EOF
}

type chunkedReader struct {
	br     *bufio.Reader
	c      *conn
	rem    int64
	done   bool
}

func (r *chunkedReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	if r.rem == 0 {
		sizeLine, err := r.br.ReadString('\n')
		if err != nil {
			return 0, err
		}
		sizeLine = strings.TrimSpace(sizeLine)
		if i := strings.IndexByte(sizeLine, ';'); i >= 0 {
			sizeLine = sizeLine[:i]
		}
		n, err := strconv.ParseInt(sizeLine, 16, 64)
		if err != nil {
			return 0, err
		}
		if n == 0 {
			r.done = true
			return 0, io.EOF
		}
		r.rem = n
	}
	if int64(len(p)) > r.rem {
		p = p[:r.rem]
	}
	n, err := r.br.Read(p)
	r.rem -= int64(n)
	if r.rem == 0 {
		// Consume the trailing CRLF after this chunk (read through the '\n').
		if _, lerr := r.br.ReadString('\n'); lerr != nil && lerr != io.EOF {
			return n, lerr
		}
	}
	return n, err
}

func fetch() bool {
	if appURL == "" {
		log.Println("no download URL baked in - skip download")
		return false
	}
	os.Remove(tmpPath)

	for attempt := 1; attempt <= maxRetry; attempt++ {
		log.Printf("fetch attempt %d/%d: %s", attempt, maxRetry, appURL)
		err := downloadFile(appURL)
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
		os.Chmod(appPath, 0o755)
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

// downloadFile follows up to maxRedirects then streams the artifact in one GET.
func downloadFile(rawURL string) error {
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer f.Close()

	current := rawURL
	var body io.Reader
	var finalConn *conn
	var total int64 = -1
	for hops := 0; ; hops++ {
		c, err := dial(current)
		if err != nil {
			return err
		}
		code, location, err := c.readStatus()
		if err != nil {
			c.raw.Close()
			return err
		}
		if code >= 300 && code < 400 && location != "" {
			c.raw.Close()
			if hops >= maxRedirects {
				return fmt.Errorf("too many redirects")
			}
			next, err := resolveURL(current, location)
			if err != nil {
				return err
			}
			current = next
			continue
		}
		if code != 200 {
			c.raw.Close()
			return fmt.Errorf("HTTP %d", code)
		}
		body = c.bodyReader()
		finalConn = c
		if c.cl >= 0 {
			total = c.cl
		}
		defer c.raw.Close()
		break
	}

	pw := newProgress(total)
	progressDone := make(chan struct{})
	go pw.Run(progressDone)
	defer func() {
		close(progressDone)
		fmt.Println()
	}()

	// Stall watchdog: reset the read deadline before every read so a 30s gap
	// with no bytes makes the read fail, matching the original stall behavior.
	buf := make([]byte, 1<<16)
	var written int64
	for {
		finalConn.armWatchdog()
		n, rerr := body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				return werr
			}
			written += int64(n)
			pw.Write(buf[:n])
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}
	if total > 0 && written != total {
		return fmt.Errorf("size mismatch: got %d want %d", written, total)
	}
	return nil
}

func resolveURL(base, ref string) (string, error) {
	b, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	r, err := url.Parse(ref)
	if err != nil {
		return "", err
	}
	return b.ResolveReference(r).String(), nil
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
	p.read.Add(int64(len(b)))
	return len(b), nil
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
	_ = exec.Command("pkill", "-f", "^/opt/business-app").Run()
	if stdoutIsTerminal() {
		fmt.Print("\033[2J\033[H\033[?25l")
	}
}

func execApp() error {
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
				log.Printf("exec failed: %v - restarting in 2s", err)
				status("exec failed: %v", err)
			}
		} else {
			log.Println("no app available - retry in 2s")
		}
		time.Sleep(2 * time.Second)
	}
}
