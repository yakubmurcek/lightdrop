// lightdrop — AirDrop in the terminal, peer-to-peer over Tailscale. No UI.
//
//	lightdrop <file or folder>...     pick a computer by number, send it there
//	lightdrop -t <device> <path>...   send without the picker
//	lightdrop install                 receive in the background, from login on
//	lightdrop uninstall               stop receiving
//	lightdrop receive [--dir D]       receive in the foreground
//	lightdrop peers                   online computers, as JSON (for the Mac app)
//
// --json makes sending print one JSON object per line on stdout (progress, then
// the result) instead of a progress bar; the Mac notch app reads it.
//
// Every machine runs a receiver on its Tailscale IP only, port 8765. It accepts
// uploads and nothing else: it never lists or serves a file, so nobody can read
// or guess what is in Downloads. What arrives goes straight into ~/Downloads; a
// name already taken there becomes "name 2", "name 3"… (decided by the receiver,
// so the sender learns nothing about what exists). A folder travels as one tar
// stream and arrives as a folder. Who may send is the tailnet policy's call.
// Taildrop can't do this: it only sends between one user's own devices.
package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

const (
	port  = 8765
	ping  = "lightdrop"
	label = "com.lightdrop.receiver"
)

// jsonOut: machine-readable output for the Mac app (--json).
var jsonOut bool

func main() {
	var args []string
	for _, a := range os.Args[1:] {
		if a == "--json" {
			jsonOut = true
			continue
		}
		args = append(args, a)
	}
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		usage()
		return
	}
	var err error
	switch args[0] {
	case "install":
		err = install()
	case "uninstall":
		err = uninstall()
	case "peers":
		err = printPeers()
	case "receive":
		dir := ""
		if len(args) >= 3 && args[1] == "--dir" {
			dir = args[2]
		}
		err = receive(dir)
	case "-t":
		if len(args) < 3 {
			err = errors.New("usage: lightdrop -t <device> <file or folder>...")
			break
		}
		err = sendAll(args[1], args[2:])
	default:
		err = sendAll("", args)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "lightdrop:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`lightdrop <file or folder>...     pick a computer by number, send it there
lightdrop -t <device> <path>...   send without the picker
lightdrop install                 receive in the background (files land in Downloads)
lightdrop uninstall               stop receiving
lightdrop peers                   online computers, as JSON

Update: run the install line again.
`)
}

// --- Tailscale -------------------------------------------------------------

func tailscaleCLI() (string, error) {
	if p, err := exec.LookPath("tailscale"); err == nil {
		// The macOS app's binary crashes when run through a symlink ("bundleIdentifier
		// is unknown to the registry"), so run what the link points at.
		if r, err := filepath.EvalSymlinks(p); err == nil {
			p = r
		}
		return p, nil
	}
	for _, p := range []string{
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
		filepath.Join(os.Getenv("ProgramFiles"), "Tailscale", "tailscale.exe"),
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p, nil
		}
	}
	return "", errors.New("Tailscale CLI not found — install Tailscale first")
}

func tsOut(args ...string) ([]byte, error) {
	ts, err := tailscaleCLI()
	if err != nil {
		return nil, err
	}
	// Bounded: outside a terminal the macOS app's CLI may never answer.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, ts, args...).Output()
}

// selfIP is this machine's Tailscale IPv4. Read from the network interfaces
// first: the macOS app's CLI does not answer when run from launchd.
func selfIP() (string, error) {
	_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && cgnat.Contains(n.IP) {
				return n.IP.String(), nil
			}
		}
	}
	out, err := tsOut("ip", "-4")
	ip := strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0])
	if err != nil || net.ParseIP(ip) == nil {
		return "", errors.New("Tailscale is not connected")
	}
	return ip, nil
}

// Owner is who the device belongs to: "you", a person's name, or "" for a server;
// Pic is the owner's profile picture URL (the Mac app shows it).
type peer struct{ Name, IP, Owner, Pic string }

func (p peer) label() string {
	if p.Owner == "" {
		return p.Name
	}
	return p.Name + " (" + p.Owner + ")"
}

// onlinePeers lists the other online devices this machine can see.
func onlinePeers() ([]peer, error) {
	out, err := tsOut("status", "--json")
	if err != nil {
		return nil, errors.New("tailscale status failed — is Tailscale running?")
	}
	return parsePeers(out)
}

func parsePeers(statusJSON []byte) ([]peer, error) {
	var st struct {
		Self struct{ UserID int64 }
		User map[string]struct {
			LoginName     string
			DisplayName   string
			ProfilePicURL string
		}
		Peer map[string]struct {
			DNSName      string
			HostName     string
			Online       bool
			TailscaleIPs []string
			UserID       int64
		}
	}
	if err := json.Unmarshal(statusJSON, &st); err != nil {
		return nil, err
	}
	var ps []peer
	for _, p := range st.Peer {
		ip := ipv4(p.TailscaleIPs)
		if !p.Online || ip == "" {
			continue
		}
		name := strings.SplitN(p.DNSName, ".", 2)[0]
		if name == "" {
			name = p.HostName
		}
		owner, pic := "", ""
		u, ok := st.User[strconv.FormatInt(p.UserID, 10)]
		if p.UserID == st.Self.UserID {
			owner, pic = "you", u.ProfilePicURL
		} else if ok && u.LoginName != "tagged-devices" {
			owner, pic = u.DisplayName, u.ProfilePicURL
			if owner == "" {
				owner = u.LoginName
			}
		}
		ps = append(ps, peer{name, ip, owner, pic})
	}
	sort.Slice(ps, func(i, j int) bool { return ps[i].label() < ps[j].label() })
	return ps, nil
}

// ipv4 picks the IPv4 address: the receiver listens on that one only.
func ipv4(ips []string) string {
	for _, s := range ips {
		if ip := net.ParseIP(s); ip != nil && ip.To4() != nil {
			return s
		}
	}
	return ""
}

func addr(ip string) string { return net.JoinHostPort(ip, strconv.Itoa(port)) }

func isReceiver(ip string) bool {
	c := http.Client{Timeout: 2 * time.Second}
	r, err := c.Get("http://" + addr(ip) + "/ping")
	if err != nil {
		return false
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(r.Body, 64))
	return r.StatusCode == 200 && string(b) == ping
}

// --- sending ---------------------------------------------------------------

func sendAll(to string, paths []string) error {
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			return fmt.Errorf("no such file or folder: %s", p)
		}
	}
	target, err := pickTarget(to)
	if err != nil {
		return err
	}
	for _, p := range paths {
		if err := sendOne(target, p); err != nil {
			return err
		}
	}
	return nil
}

// printPeers lists the online computers with whether each one is receiving.
func printPeers() error {
	ps, err := onlinePeers()
	if err != nil {
		return err
	}
	type row struct {
		Name      string `json:"name"`
		IP        string `json:"ip"`
		Owner     string `json:"owner"`
		Receiving bool   `json:"receiving"`
		Pic       string `json:"pic,omitempty"`
	}
	rows := make([]row, len(ps))
	var wg sync.WaitGroup
	for i, p := range ps {
		rows[i] = row{p.Name, p.IP, p.Owner, false, p.Pic}
		wg.Add(1)
		go func(i int, ip string) {
			defer wg.Done()
			rows[i].Receiving = isReceiver(ip)
		}(i, p.IP)
	}
	wg.Wait()
	return json.NewEncoder(os.Stdout).Encode(rows)
}

// emit prints one JSON line on stdout (--json).
func emit(v map[string]any) {
	b, _ := json.Marshal(v)
	os.Stdout.Write(append(b, '\n'))
}

func pickTarget(to string) (peer, error) {
	ps, err := onlinePeers()
	if err != nil {
		return peer{}, err
	}
	if to != "" {
		var hits []peer
		for _, p := range ps {
			if strings.EqualFold(p.Name, to) || p.IP == to {
				hits = append(hits, p)
			}
		}
		switch len(hits) {
		case 0:
			return peer{}, fmt.Errorf("%s is not online on the tailnet", to)
		case 1:
			return hits[0], nil
		}
		var ls []string
		for _, p := range hits {
			ls = append(ls, p.label()+" "+p.IP)
		}
		return peer{}, fmt.Errorf("several computers are called %s, use the IP instead: %s", to, strings.Join(ls, ", "))
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	var rs []peer
	for _, p := range ps {
		wg.Add(1)
		go func(p peer) {
			defer wg.Done()
			if isReceiver(p.IP) {
				mu.Lock()
				rs = append(rs, p)
				mu.Unlock()
			}
		}(p)
	}
	wg.Wait()
	sort.Slice(rs, func(i, j int) bool { return rs[i].label() < rs[j].label() })
	if len(rs) == 0 {
		return peer{}, errors.New("no device is receiving (on the other machine: lightdrop install)")
	}
	// Always ask, even with one receiver: with friends on the tailnet the only
	// one online may be someone else's computer.
	for i, p := range rs {
		fmt.Printf("  %d) %s\n", i+1, p.label())
	}
	fmt.Print("send to: ")
	var line string
	fmt.Scanln(&line)
	n, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil || n < 1 || n > len(rs) {
		return peer{}, errors.New("no such choice")
	}
	return rs[n-1], nil
}

func sendOne(to peer, path string) error {
	path = filepath.Clean(path)
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	name := filepath.Base(path)
	kind, size := "file", st.Size()
	var body io.Reader
	if st.IsDir() {
		kind = "dir"
		size = 0
		// The tar stream's size: per entry a header (PAX adds up to two more
		// blocks) and the content padded to 512 bytes, plus the closing blocks.
		size = 1024
		filepath.WalkDir(path, func(_ string, d fs.DirEntry, err error) error {
			if err == nil && (d.IsDir() || d.Type().IsRegular()) {
				size += 3 * 512
				if i, e := d.Info(); e == nil && d.Type().IsRegular() {
					size += (i.Size() + 511) / 512 * 512
				}
			}
			return nil
		})
		pr, pw := io.Pipe()
		go func() { pw.CloseWithError(writeTar(pw, path)) }()
		body = pr
	} else {
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		body = f
	}
	prog := &progress{total: size, label: name}
	host, _ := os.Hostname()
	u := fmt.Sprintf("http://%s/send?kind=%s&name=%s&from=%s", addr(to.IP), kind,
		url.QueryEscape(name), url.QueryEscape(strings.SplitN(host, ".", 2)[0]))
	req, err := http.NewRequest(http.MethodPost, u, io.TeeReader(body, prog))
	if err != nil {
		return err
	}
	if kind == "file" {
		req.ContentLength = size
	}
	resp, err := http.DefaultClient.Do(req)
	prog.done()
	if err != nil {
		return fmt.Errorf("sending %s to %s: %v", name, to.Name, err)
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s refused %s: %s", to.Name, name, strings.TrimSpace(string(msg)))
	}
	saved := strings.TrimSpace(string(msg))
	if jsonOut {
		emit(map[string]any{"event": "sent", "file": name, "saved": saved, "to": to.label()})
		return nil
	}
	if saved != name {
		fmt.Printf("sent %s → %s (saved as %q)\n", name, to.Name, saved)
	} else {
		fmt.Printf("sent %s → %s\n", name, to.Name)
	}
	return nil
}

// writeTar streams a folder's regular files and subfolders (symlinks skipped).
func writeTar(w io.Writer, root string) error {
	tw := tar.NewWriter(w)
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if rel == "." || !(d.IsDir() || d.Type().IsRegular()) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		h := &tar.Header{Name: filepath.ToSlash(rel), Mode: 0o644, ModTime: info.ModTime(), Format: tar.FormatPAX}
		if d.IsDir() {
			h.Typeflag, h.Name, h.Mode = tar.TypeDir, h.Name+"/", 0o755
			return tw.WriteHeader(h)
		}
		h.Typeflag, h.Size = tar.TypeReg, info.Size()
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(tw, f)
		return err
	})
	if err != nil {
		return err
	}
	return tw.Close()
}

type progress struct {
	total, n int64
	label    string
	last     time.Time
}

func (p *progress) Write(b []byte) (int, error) {
	p.n += int64(len(b))
	if time.Since(p.last) > 150*time.Millisecond {
		p.last = time.Now()
		p.print()
	}
	return len(b), nil
}

func (p *progress) print() {
	if jsonOut {
		emit(map[string]any{"event": "progress", "file": p.label, "sent": p.n, "total": p.total})
		return
	}
	pct := 100.0
	if p.total > 0 && p.n < p.total {
		pct = float64(p.n) * 100 / float64(p.total)
	}
	fmt.Fprintf(os.Stderr, "\r  %s  %5.1f%%  %s", p.label, pct, human(p.n))
}

func (p *progress) done() {
	p.print()
	if !jsonOut {
		fmt.Fprintln(os.Stderr)
	}
}

func human(n int64) string {
	f, u := float64(n), "B"
	for _, x := range []string{"KB", "MB", "GB", "TB"} {
		if f < 1024 {
			break
		}
		f, u = f/1024, x
	}
	return fmt.Sprintf("%.1f %s", f, u)
}

// --- receiving -------------------------------------------------------------

func downloadsDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Downloads")
}

func receive(dir string) error {
	if dir == "" {
		dir = downloadsDir()
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// At login Tailscale may not be up yet: wait for its address instead of failing.
	var ip string
	for {
		var err error
		if ip, err = selfIP(); err == nil {
			break
		}
		time.Sleep(5 * time.Second)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		io.WriteString(w, ping)
	})
	mux.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) { handleSend(w, r, dir) })
	srv := &http.Server{
		Addr:              addr(ip),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	fmt.Printf("lightdrop: receiving on %s, saving to %s\n", srv.Addr, dir)
	return srv.ListenAndServe()
}

func handleSend(w http.ResponseWriter, r *http.Request, dir string) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	name := safeName(r.URL.Query().Get("name"))
	if name == "" {
		http.Error(w, "bad name", http.StatusBadRequest)
		return
	}
	var saved string
	var err error
	switch r.URL.Query().Get("kind") {
	case "file":
		saved, err = receiveFile(dir, name, r.Body)
	case "dir":
		saved, err = receiveDir(dir, name, r.Body)
	default:
		http.Error(w, "bad kind", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	io.WriteString(w, saved)
	go notify(saved, sender(r.RemoteAddr, r.URL.Query().Get("from")))
}

// safeName keeps one path component, with characters no OS accepts replaced.
func safeName(s string) string {
	s = strings.Map(func(c rune) rune {
		if c < 32 || strings.ContainsRune(`<>:"/\|?*`, c) {
			return '_'
		}
		return c
	}, s)
	s = strings.TrimRight(strings.TrimSpace(s), ". ")
	if s == "" || s == "." || s == ".." {
		return ""
	}
	return s
}

// candidates yields name, "stem 2.ext", "stem 3.ext"…
func candidate(name string, n int, isDir bool) string {
	if n == 1 {
		return name
	}
	ext := ""
	if !isDir {
		ext = filepath.Ext(name)
		if ext == name {
			ext = ""
		}
	}
	return fmt.Sprintf("%s %d%s", strings.TrimSuffix(name, ext), n, ext)
}

func receiveFile(dir, name string, body io.Reader) (string, error) {
	for n := 1; n < 10000; n++ {
		c := candidate(name, n, false)
		p := filepath.Join(dir, c)
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		_, err = io.Copy(f, body)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			os.Remove(p)
			return "", err
		}
		return c, nil
	}
	return "", errors.New("no free name")
}

func receiveDir(dir, name string, body io.Reader) (string, error) {
	for n := 1; n < 10000; n++ {
		c := candidate(name, n, true)
		root := filepath.Join(dir, c)
		err := os.Mkdir(root, 0o755)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		if err := untar(root, body); err != nil {
			os.RemoveAll(root)
			return "", err
		}
		return c, nil
	}
	return "", errors.New("no free name")
}

// untar extracts regular files and folders only, each path component cleaned,
// so nothing can land outside root.
func untar(root string, body io.Reader) error {
	tr := tar.NewReader(body)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		var parts []string
		for _, s := range strings.Split(h.Name, "/") {
			if s == "" || s == "." {
				continue
			}
			if s = safeName(s); s == "" {
				return fmt.Errorf("bad path %q", h.Name)
			}
			parts = append(parts, s)
		}
		if len(parts) == 0 {
			continue
		}
		p := filepath.Join(append([]string{root}, parts...)...)
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
			if err != nil {
				return err
			}
			_, err = io.Copy(f, tr)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return err
			}
			os.Chtimes(p, h.ModTime, h.ModTime)
		}
	}
}

// sender names the device a transfer came from: tailscale whois where the CLI
// answers, else the name the sender gave plus its Tailscale IP.
func sender(remote, claimed string) string {
	ip, _, _ := net.SplitHostPort(remote)
	host := ip
	if c := safeName(claimed); c != "" {
		host = c + " (" + ip + ")"
	}
	out, err := tsOut("whois", "--json", ip)
	if err != nil {
		return host
	}
	var w struct {
		Node        struct{ ComputedName string }
		UserProfile struct{ DisplayName string }
	}
	if json.Unmarshal(out, &w) != nil || w.Node.ComputedName == "" {
		return host
	}
	if w.UserProfile.DisplayName != "" {
		return w.UserProfile.DisplayName + " (" + w.Node.ComputedName + ")"
	}
	return w.Node.ComputedName
}

func notify(saved, from string) {
	msg := fmt.Sprintf("%s from %s", saved, from)
	fmt.Println("received", msg)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	switch runtime.GOOS {
	case "darwin":
		script := fmt.Sprintf("display notification %q with title \"lightdrop\" subtitle \"in Downloads\"", msg)
		exec.CommandContext(ctx, "osascript", "-e", script).Run()
	case "linux":
		if p, err := exec.LookPath("notify-send"); err == nil {
			exec.CommandContext(ctx, p, "lightdrop", msg+" — in Downloads").Run()
		}
	}
}

// --- install ---------------------------------------------------------------

func install() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "windows":
		return installWindows(self)
	case "darwin", "linux":
	default:
		return fmt.Errorf("install is not supported on %s; run: lightdrop receive", runtime.GOOS)
	}
	home, _ := os.UserHomeDir()
	bin := filepath.Join(home, ".local", "bin")
	dest := filepath.Join(bin, "lightdrop")
	if err := copySelf(self, dest); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		plist := filepath.Join(home, "Library", "LaunchAgents", label+".plist")
		os.MkdirAll(filepath.Dir(plist), 0o755)
		content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array><string>%s</string><string>receive</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict></plist>
`, label, dest, filepath.Join(home, "Library", "Logs", "lightdrop.log"), filepath.Join(home, "Library", "Logs", "lightdrop.log"))
		if err := os.WriteFile(plist, []byte(content), 0o644); err != nil {
			return err
		}
		uid := strconv.Itoa(os.Getuid())
		exec.Command("launchctl", "bootout", "gui/"+uid+"/"+label).Run()
		// bootout returns before the old receiver is gone; bootstrapping meanwhile
		// fails with "5: Input/output error", so wait and retry (an update reinstalls).
		var out []byte
		for i := 0; i < 20; i++ {
			if out, err = exec.Command("launchctl", "bootstrap", "gui/"+uid, plist).CombinedOutput(); err == nil {
				break
			}
			time.Sleep(500 * time.Millisecond)
		}
		if err != nil {
			return fmt.Errorf("launchctl: %s", out)
		}
	} else {
		unit := filepath.Join(home, ".config", "systemd", "user", "lightdrop.service")
		os.MkdirAll(filepath.Dir(unit), 0o755)
		content := fmt.Sprintf(`[Unit]
Description=lightdrop receiver (Tailscale only, saves to ~/Downloads)

[Service]
ExecStart=%s receive
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
`, dest)
		if err := os.WriteFile(unit, []byte(content), 0o644); err != nil {
			return err
		}
		for _, a := range [][]string{{"daemon-reload"}, {"enable", "lightdrop.service"}, {"restart", "lightdrop.service"}} {
			if out, err := exec.Command("systemctl", append([]string{"--user"}, a...)...).CombinedOutput(); err != nil {
				return fmt.Errorf("systemctl --user %s: %s", strings.Join(a, " "), out)
			}
		}
	}
	fmt.Println("lightdrop: receiving in the background — files sent here land in", downloadsDir())
	if !onPath(bin) {
		rc, err := addToPath(home, os.Getenv("SHELL"))
		if err != nil {
			fmt.Printf("lightdrop: add %s to your PATH to run lightdrop from anywhere\n", bin)
		} else {
			fmt.Printf("lightdrop: added %s to your PATH in %s — open a new terminal to use lightdrop\n", bin, rc)
		}
	}
	return nil
}

func onPath(dir string) bool {
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if filepath.Clean(p) == dir {
			return true
		}
	}
	return false
}

// addToPath puts ~/.local/bin on the PATH in the login shell's startup file,
// once, and returns that file.
func addToPath(home, shell string) (string, error) {
	rc, line := filepath.Join(home, ".profile"), `export PATH="$HOME/.local/bin:$PATH"`
	switch filepath.Base(shell) {
	case "zsh":
		rc = filepath.Join(home, ".zshrc")
	case "bash":
		rc = filepath.Join(home, ".bashrc")
		if runtime.GOOS == "darwin" {
			rc = filepath.Join(home, ".bash_profile")
		}
	case "fish":
		rc, line = filepath.Join(home, ".config", "fish", "config.fish"), "fish_add_path $HOME/.local/bin"
	}
	if b, err := os.ReadFile(rc); err == nil && strings.Contains(string(b), ".local/bin") {
		return rc, nil
	}
	os.MkdirAll(filepath.Dir(rc), 0o755)
	f, err := os.OpenFile(rc, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return "", err
	}
	_, err = fmt.Fprintf(f, "\n%s  # lightdrop\n", line)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return rc, err
}

func copySelf(self, dest string) error {
	if a, err := filepath.EvalSymlinks(self); err == nil {
		self = a
	}
	if b, err := filepath.EvalSymlinks(dest); err == nil && b == self {
		return nil
	}
	data, err := os.ReadFile(self)
	if err != nil {
		return err
	}
	os.MkdirAll(filepath.Dir(dest), 0o755)
	tmp := dest + ".new"
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

// Windows: the binary goes to %LOCALAPPDATA%\lightdrop (on the user PATH); one
// elevated step adds a firewall rule (this program, TCP 8765, Tailscale addresses
// only) and a hidden scheduled task that receives from startup.
func installWindows(self string) error {
	dir := filepath.Join(os.Getenv("LOCALAPPDATA"), "lightdrop")
	dest := filepath.Join(dir, "lightdrop.exe")
	// A running receiver locks the exe; stop it before replacing.
	runPS(`Stop-ScheduledTask -TaskName 'lightdrop receiver' -EA SilentlyContinue`)
	time.Sleep(time.Second)
	if err := copySelf(self, dest); err != nil {
		return err
	}
	if err := runPS(fmt.Sprintf(`$p=[Environment]::GetEnvironmentVariable('Path','User'); if (($p -split ';') -notcontains '%s') { [Environment]::SetEnvironmentVariable('Path', "$p;%s", 'User') }`, dir, dir)); err != nil {
		return err
	}
	admin := fmt.Sprintf(`
Remove-NetFirewallRule -DisplayName 'lightdrop' -EA SilentlyContinue
New-NetFirewallRule -DisplayName 'lightdrop' -Direction Inbound -Action Allow -Program '%[1]s' -Protocol TCP -LocalPort %[2]d -RemoteAddress 100.64.0.0/10 | Out-Null
$a = New-ScheduledTaskAction -Execute '%[1]s' -Argument 'receive --dir "%[3]s"'
$t = New-ScheduledTaskTrigger -AtStartup
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$u = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U
Register-ScheduledTask -TaskName 'lightdrop receiver' -Action $a -Trigger $t -Settings $s -Principal $u -Force | Out-Null
Start-ScheduledTask -TaskName 'lightdrop receiver'
`, dest, port, downloadsDir())
	if err := runElevated(admin); err != nil {
		return err
	}
	fmt.Println("lightdrop: receiving in the background — files sent here land in", downloadsDir())
	fmt.Println("lightdrop: open a new terminal to use the lightdrop command")
	return nil
}

func uninstall() error {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "darwin":
		exec.Command("launchctl", "bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+label).Run()
		os.Remove(filepath.Join(home, "Library", "LaunchAgents", label+".plist"))
	case "linux":
		exec.Command("systemctl", "--user", "disable", "--now", "lightdrop.service").Run()
		os.Remove(filepath.Join(home, ".config", "systemd", "user", "lightdrop.service"))
	case "windows":
		if err := runElevated(`Unregister-ScheduledTask -TaskName 'lightdrop receiver' -Confirm:$false -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName 'lightdrop' -EA SilentlyContinue`); err != nil {
			return err
		}
	}
	fmt.Println("lightdrop: not receiving any more")
	return nil
}

func runPS(script string) error {
	script = "$ProgressPreference='SilentlyContinue'\n" + script
	out, err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePS(script)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("powershell: %v: %s", err, out)
	}
	return nil
}

// runElevated runs a script as admin: directly when already elevated, else via UAC.
func runElevated(script string) error {
	if exec.Command("net", "session").Run() == nil {
		return runPS(script)
	}
	wrap := fmt.Sprintf(`$p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','%s'; exit $p.ExitCode`, encodePS("$ErrorActionPreference='Stop'\n"+script))
	return runPS(wrap)
}

func encodePS(s string) string {
	var b bytes.Buffer
	for _, c := range utf16.Encode([]rune(s)) {
		b.WriteByte(byte(c))
		b.WriteByte(byte(c >> 8))
	}
	return base64.StdEncoding.EncodeToString(b.Bytes())
}
