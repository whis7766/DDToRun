// app-runner downloads a business binary and executes it in place.
//
// The HTTP client is deliberately hand-written on top of crypto/tls instead of
// net/http: net/http pulls in HTTP/2, the transport abstraction and vendored
// golang.org/x/net, which is a large part of this binary. Only what the
// appliance actually needs is kept - a single-stream GET, up to ten redirects,
// chunked and Content-Length bodies, a stall watchdog via read deadlines and
// fixed retries.
package main

import (
	"bufio"
	"crypto/tls"
	"errors"
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
	maxRetry     = 6
	maxRedirects = 10
	retryDelay   = 3 * time.Second
	stallTimeout = 30 * time.Second
	userAgent    = "app-runner/1.0"

	dialTimeout      = 15 * time.Second
	handshakeTimeout = 10 * time.Second
	restartDelay     = 2 * time.Second
)

var (
	appPath = "/opt/business-app"
	tmpPath = "/opt/business-app.tmp"
	appURL  = "https://furryfree.pages.dev/release?token=jaJ81HfL&filename=subs-check_linux_amd64v3&tag=ctyun"

	// progressInline redraws one line with a carriage return, which is what the
	// kiosk wants on the framebuffer. It is selected by an explicit flag rather
	// than by inspecting stdout: the kiosk pipes the runner through tee, so
	// stdout is a pipe there too and tty detection would get it wrong. In the
	// service profile stdout is a log file and the line mode keeps it readable.
	progressInline bool
)

// errTooManyRedirects bounds the redirect chain.
var errTooManyRedirects = errors.New("too many redirects")

// --- logging ---------------------------------------------------------------

// statusf writes one progress line to stdout. The kiosk profile pipes stdout
// into fbterm; the headless profile sends it to the service log.
func statusf(format string, args ...any) {
	fmt.Printf("[app-runner] "+format+"\n", args...)
}

// openLog returns stdout. Persistence is owned by the service layer: the kiosk
// launcher tees stdout to the log, the headless supervise-daemon redirects it
// to output_log. The runner must not open its own log file, or every line would
// be written twice in the headless profile.
func openLog() io.Writer {
	return os.Stdout
}

// --- HTTP/1.1 client -------------------------------------------------------

// response is one complete HTTP response with its body already decoded.
type response struct {
	code     int
	location string
	length   int64 // Content-Length, or -1 when absent
	chunked  bool
	body     io.Reader
	conn     net.Conn
}

func (r *response) close() { r.conn.Close() }

// request performs one GET against rawURL and returns the parsed response.
func request(rawURL string) (*response, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}

	conn, err := dial(u)
	if err != nil {
		return nil, err
	}

	if _, err := io.WriteString(conn, buildRequest(u)); err != nil {
		conn.Close()
		return nil, err
	}

	br := bufio.NewReaderSize(conn, 64<<10)
	resp, err := readHead(br)
	if err != nil {
		conn.Close()
		return nil, err
	}
	resp.conn = conn
	resp.body = bodyReader(br, resp)
	return resp, nil
}

// dial opens the TCP (and, for https, TLS) connection for u.
func dial(u *url.URL) (net.Conn, error) {
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}

	d := &net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}
	raw, err := d.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, err
	}
	if u.Scheme != "https" {
		return raw, nil
	}

	tc := tls.Client(raw, &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: host,
	})
	tc.SetDeadline(time.Now().Add(handshakeTimeout))
	if err := tc.Handshake(); err != nil {
		raw.Close()
		return nil, err
	}
	tc.SetDeadline(time.Time{})
	return tc, nil
}

func buildRequest(u *url.URL) string {
	target := u.RequestURI()
	if target == "" || target == u.Host {
		target = "/"
	}
	return "GET " + target + " HTTP/1.1\r\n" +
		"Host: " + u.Host + "\r\n" +
		"User-Agent: " + userAgent + "\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n\r\n"
}

// readHead parses the status line and the headers we care about.
func readHead(br *bufio.Reader) (*response, error) {
	line, err := br.ReadString('\n')
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(line), " ")
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return nil, fmt.Errorf("bad status line: %q", line)
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return nil, err
	}

	resp := &response{code: code, length: -1}
	for {
		h, err := br.ReadString('\n')
		if err != nil {
			return nil, err
		}
		h = strings.TrimSpace(h)
		if h == "" {
			return resp, nil
		}
		colon := strings.IndexByte(h, ':')
		if colon < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(h[:colon]))
		value := strings.TrimSpace(h[colon+1:])
		switch key {
		case "content-length":
			if n, err := strconv.ParseInt(value, 10, 64); err == nil {
				resp.length = n
			}
		case "transfer-encoding":
			if strings.Contains(strings.ToLower(value), "chunked") {
				resp.chunked = true
				resp.length = -1
			}
		case "location":
			resp.location = value
		}
	}
}

// bodyReader wraps br in the decoder implied by the response headers.
func bodyReader(br *bufio.Reader, r *response) io.Reader {
	switch {
	case r.chunked:
		return &chunkedReader{br: br}
	case r.length >= 0:
		return io.LimitReader(br, r.length)
	default:
		// Connection: close - the body ends at EOF.
		return br
	}
}

// chunkedReader decodes the chunked transfer encoding.
type chunkedReader struct {
	br   *bufio.Reader
	left int64
	done bool
}

func (r *chunkedReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	if r.left == 0 {
		n, err := r.readSize()
		if err != nil {
			return 0, err
		}
		if n == 0 {
			r.done = true
			return 0, io.EOF
		}
		r.left = n
	}
	if int64(len(p)) > r.left {
		p = p[:r.left]
	}
	n, err := r.br.Read(p)
	r.left -= int64(n)
	if r.left == 0 {
		// Discard the CRLF that terminates this chunk.
		if _, lerr := r.br.ReadString('\n'); lerr != nil && lerr != io.EOF {
			return n, lerr
		}
	}
	return n, err
}

// readSize parses one chunk-size line, ignoring extensions.
func (r *chunkedReader) readSize() (int64, error) {
	line, err := r.br.ReadString('\n')
	if err != nil {
		return 0, err
	}
	line = strings.TrimSpace(line)
	if i := strings.IndexByte(line, ';'); i >= 0 {
		line = line[:i]
	}
	return strconv.ParseInt(line, 16, 64)
}

// openURL follows redirects and returns the final 200 response.
func openURL(rawURL string) (*response, error) {
	current := rawURL
	for hop := 0; ; hop++ {
		resp, err := request(current)
		if err != nil {
			return nil, err
		}
		if resp.code >= 300 && resp.code < 400 && resp.location != "" {
			resp.close()
			if hop >= maxRedirects {
				return nil, errTooManyRedirects
			}
			if current, err = resolveReference(current, resp.location); err != nil {
				return nil, err
			}
			continue
		}
		if resp.code != 200 {
			resp.close()
			return nil, fmt.Errorf("HTTP %d", resp.code)
		}
		return resp, nil
	}
}

// resolveReference resolves ref against base, allowing relative Location
// headers (the common "/release?..." form).
func resolveReference(base, ref string) (string, error) {
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

// --- download --------------------------------------------------------------

// downloadOnce streams rawURL into dest in one GET. The read deadline is
// re-armed before every read, so a stallTimeout gap with no bytes fails the
// attempt instead of hanging.
func downloadOnce(rawURL, dest string) error {
	resp, err := openURL(rawURL)
	if err != nil {
		return err
	}
	defer resp.close()

	f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer f.Close()

	p := newProgress(resp.length)
	stop := make(chan struct{})
	go p.run(stop)
	defer func() {
		close(stop)
		fmt.Println()
	}()

	buf := make([]byte, 64<<10)
	var written int64
	for {
		resp.conn.SetReadDeadline(time.Now().Add(stallTimeout))

		n, rerr := resp.body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				return werr
			}
			written += int64(n)
			p.add(int64(n))
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}

	if resp.length > 0 && written != resp.length {
		return fmt.Errorf("size mismatch: got %d want %d", written, resp.length)
	}
	return nil
}

// fetchApp downloads the binary with fixed retries and atomically replaces the
// installed one. It reports whether a usable binary is in place when it returns
// - a successful download, or an already-installed copy that was left alone.
func fetchApp() bool {
	if appURL == "" {
		log.Println("no download URL baked in - skip download")
		return appPresent()
	}
	os.Remove(tmpPath)

	for attempt := 1; attempt <= maxRetry; attempt++ {
		log.Printf("fetch attempt %d/%d: %s", attempt, maxRetry, appURL)

		err := downloadOnce(appURL, tmpPath)
		if err == nil {
			err = os.Rename(tmpPath, appPath)
		}
		if err != nil {
			log.Printf("download failed: %v", err)
			statusf("download failed (%d/%d): %v", attempt, maxRetry, err)
			// Never leave a partial file behind; the next attempt starts clean.
			os.Remove(tmpPath)
			if attempt < maxRetry {
				time.Sleep(retryDelay)
			}
			continue
		}

		os.Chmod(appPath, 0o755)
		if fi, statErr := os.Stat(appPath); statErr == nil {
			log.Printf("downloaded new version (%d bytes)", fi.Size())
			statusf("downloaded new version: %d bytes", fi.Size())
		}
		return true
	}

	os.Remove(tmpPath)
	if appPresent() {
		statusf("using existing local app")
		return true
	}
	statusf("no local app available")
	return false
}

func appPresent() bool {
	fi, err := os.Stat(appPath)
	return err == nil && fi.Size() > 0
}

// --- progress --------------------------------------------------------------

type progress struct {
	total int64
	read  atomic.Int64
}

func newProgress(total int64) *progress { return &progress{total: total} }

func (p *progress) add(n int64) { p.read.Add(n) }

// run prints a status line every 500ms until stop is closed. Only the ticker
// goroutine touches its own bookkeeping, so the counters stay cheap.
func (p *progress) run(stop <-chan struct{}) {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	// The kiosk redraws a single progress line; the log line mode always starts
	// a new line, so a service log stays readable.
	nl := "\n"
	if progressInline {
		nl = "\r"
	}

	lastBytes := int64(0)
	lastTime := time.Now()
	for {
		select {
		case now := <-ticker.C:
			cur := p.read.Load()
			dt := now.Sub(lastTime).Seconds()
			lastTime = now
			if dt <= 0 {
				continue
			}
			speed := float64(cur-lastBytes) / dt / 1048576
			lastBytes = cur

			if p.total > 0 {
				fmt.Printf(nl+"[app-runner] download %3d%% %5.1f/%5.1fMB %4.1fMB/s ",
					cur*100/p.total, megabytes(cur), megabytes(p.total), speed)
			} else {
				fmt.Printf(nl+"[app-runner] download %5.1fMB %4.1fMB/s ",
					megabytes(cur), speed)
			}
		case <-stop:
			return
		}
	}
}

func megabytes(n int64) float64 { return float64(n) / 1048576 }

// --- execution -------------------------------------------------------------

// prepareBeforeExec clears the console and kills any stale business process so
// the replacement can bind its ports. The clear only makes sense when the
// console is owned by the kiosk launcher, i.e. in inline mode.
func prepareBeforeExec() {
	_ = exec.Command("pkill", "-f", "^"+appPath).Run()
	if progressInline {
		fmt.Print("\033[2J\033[H\033[?25l")
	}
}

// execApp replaces this process with the business binary, inheriting nothing
// from the runner environment except a fixed PATH.
func execApp() error {
	env := []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
	return syscall.Exec(appPath, []string{appPath}, env)
}

func parseArgs(args []string) {
	for _, arg := range args {
		if arg == "--progress=inline" {
			progressInline = true
		}
	}
}

func main() {
	parseArgs(os.Args[1:])
	log.SetOutput(openLog())
	log.Println("app-runner starting")

	for {
		if fetchApp() {
			log.Println("running", appPath)
			prepareBeforeExec()
			if err := execApp(); err != nil {
				log.Printf("exec failed: %v - restarting in %s", err, restartDelay)
				statusf("exec failed: %v", err)
			}
		} else {
			log.Printf("no app available - retry in %s", restartDelay)
		}
		time.Sleep(restartDelay)
	}
}
