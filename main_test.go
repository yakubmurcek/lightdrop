package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSafeName(t *testing.T) {
	for in, want := range map[string]string{
		"report.txt":    "report.txt",
		"žluťoučký kůň": "žluťoučký kůň",
		"../etc/passwd": ".._etc_passwd",
		"a:b?c":         "a_b_c",
		"..":            "",
		".":             "",
		"  ":            "",
		"trailing. ":    "trailing",
		"back\\slash":   "back_slash",
	} {
		if got := safeName(in); got != want {
			t.Errorf("safeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCandidate(t *testing.T) {
	cases := []struct {
		name  string
		n     int
		isDir bool
		want  string
	}{
		{"a.txt", 1, false, "a.txt"},
		{"a.txt", 2, false, "a 2.txt"},
		{"archive.tar.gz", 3, false, "archive.tar 3.gz"},
		{".env", 2, false, ".env 2"},
		{"My Folder", 2, true, "My Folder 2"},
		{"v1.2", 2, true, "v1.2 2"},
	}
	for _, c := range cases {
		if got := candidate(c.name, c.n, c.isDir); got != c.want {
			t.Errorf("candidate(%q,%d,%v) = %q, want %q", c.name, c.n, c.isDir, got, c.want)
		}
	}
}

func TestReceiveFileNeverOverwrites(t *testing.T) {
	dir := t.TempDir()
	for i, want := range []string{"x.txt", "x 2.txt", "x 3.txt"} {
		got, err := receiveFile(dir, "x.txt", strings.NewReader(strings.Repeat("a", i+1)))
		if err != nil || got != want {
			t.Fatalf("receive %d: got %q, %v; want %q", i, got, err, want)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "x.txt")); string(b) != "a" {
		t.Fatalf("first file was overwritten: %q", b)
	}
}

func TestFolderRoundTripStaysInside(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sub dir", "empty"), 0o755)
	os.WriteFile(filepath.Join(src, "a.txt"), []byte("one"), 0o644)
	os.WriteFile(filepath.Join(src, "sub dir", "kůň.md"), []byte("tři"), 0o644)
	var buf bytes.Buffer
	if err := writeTar(&buf, src); err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	for _, want := range []string{"F", "F 2"} {
		got, err := receiveDir(dst, "F", bytes.NewReader(buf.Bytes()))
		if err != nil || got != want {
			t.Fatalf("got %q, %v; want %q", got, err, want)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "F 2", "sub dir", "kůň.md")); string(b) != "tři" {
		t.Fatalf("nested file: %q", b)
	}
	if st, err := os.Stat(filepath.Join(dst, "F", "sub dir", "empty")); err != nil || !st.IsDir() {
		t.Fatal("empty folder not kept")
	}

	// An absolute path lands inside the folder.
	var abs bytes.Buffer
	tw := tar.NewWriter(&abs)
	tw.WriteHeader(&tar.Header{Name: "/abs.txt", Typeflag: tar.TypeReg, Size: 1, Mode: 0o644})
	tw.Write([]byte("x"))
	tw.Close()
	got, err := receiveDir(dst, "abs", &abs)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dst, got, "abs.txt")); err != nil {
		t.Fatal("absolute path not kept inside the folder")
	}

	// A ".." path refuses the whole transfer and leaves nothing behind.
	var evil bytes.Buffer
	tw = tar.NewWriter(&evil)
	tw.WriteHeader(&tar.Header{Name: "../../escape.txt", Typeflag: tar.TypeReg, Size: 1, Mode: 0o644})
	tw.Write([]byte("x"))
	tw.Close()
	if _, err := receiveDir(dst, "evil", &evil); err == nil {
		t.Fatal("hostile archive accepted")
	}
	if _, err := os.Stat(filepath.Join(dst, "evil")); err == nil {
		t.Fatal("partial folder left behind")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dst), "escape.txt")); err == nil {
		t.Fatal("escaped the target folder")
	}
}

func TestIPv4(t *testing.T) {
	if got := ipv4([]string{"fd7a:115c:a1e0::1", "100.64.0.7"}); got != "100.64.0.7" {
		t.Fatalf("ipv4 = %q", got)
	}
	if got := ipv4([]string{"fd7a:115c:a1e0::1"}); got != "" {
		t.Fatalf("ipv4 without v4 = %q", got)
	}
	if got := addr("100.64.0.7"); got != "100.64.0.7:8765" {
		t.Fatalf("addr = %q", got)
	}
}

func TestAddToPathOnce(t *testing.T) {
	home := t.TempDir()
	for i := 0; i < 2; i++ {
		rc, err := addToPath(home, "/bin/zsh")
		if err != nil || rc != filepath.Join(home, ".zshrc") {
			t.Fatalf("addToPath: %q, %v", rc, err)
		}
	}
	b, _ := os.ReadFile(filepath.Join(home, ".zshrc"))
	if n := strings.Count(string(b), ".local/bin"); n != 1 {
		t.Fatalf("PATH line written %d times:\n%s", n, b)
	}
	if rc, _ := addToPath(home, "/usr/bin/fish"); !strings.HasSuffix(rc, "config.fish") {
		t.Fatalf("fish rc = %q", rc)
	}
}

func TestParsePeersLabelsOwners(t *testing.T) {
	status := []byte(`{
	  "Self": {"UserID": 1},
	  "User": {
	    "1": {"LoginName": "me@example.com", "DisplayName": "Me"},
	    "2": {"LoginName": "sam@example.com", "DisplayName": "Sam", "ProfilePicURL": "https://example.com/o.png"},
	    "3": {"LoginName": "tagged-devices", "DisplayName": "tagged-devices"}
	  },
	  "Peer": {
	    "a": {"DNSName": "macbook.tail.ts.net.", "Online": true, "TailscaleIPs": ["fd7a::1", "100.64.0.1"], "UserID": 1},
	    "b": {"DNSName": "macbook-1.tail.ts.net.", "HostName": "macbook", "Online": true, "TailscaleIPs": ["100.64.0.2"], "UserID": 2},
	    "c": {"DNSName": "box.tail.ts.net.", "Online": true, "TailscaleIPs": ["100.64.0.3"], "UserID": 3},
	    "d": {"DNSName": "ipad.tail.ts.net.", "Online": false, "TailscaleIPs": ["100.64.0.4"], "UserID": 1}
	  }
	}`)
	ps, err := parsePeers(status)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, p := range ps {
		got = append(got, p.label()+" "+p.IP)
	}
	want := "box 100.64.0.3|macbook (you) 100.64.0.1|macbook-1 (Sam) 100.64.0.2"
	if ps[2].Pic != "https://example.com/o.png" || ps[0].Pic != "" {
		t.Fatalf("profile pictures: %q, %q", ps[2].Pic, ps[0].Pic)
	}
	if strings.Join(got, "|") != want {
		t.Fatalf("got %q\nwant %q", strings.Join(got, "|"), want)
	}
}

// subscribe opens a fresh event socket and connects to it, like the Mac app does.
func subscribe(t *testing.T) (*bufio.Scanner, net.Conn, string) {
	t.Helper()
	sock, _ := os.MkdirTemp("", "ld") // a Unix socket path must stay short
	t.Cleanup(func() { os.RemoveAll(sock) })
	path := filepath.Join(sock, "s")
	if err := events.listen(path); err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	for !events.watched() {
		time.Sleep(10 * time.Millisecond)
	}
	return bufio.NewScanner(c), c, path
}

// next returns the next event that isn't progress.
func next(t *testing.T, sc *bufio.Scanner) map[string]any {
	t.Helper()
	for sc.Scan() {
		var ev map[string]any
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("bad event line %q", sc.Bytes())
		}
		if ev["event"] != "progress" {
			return ev
		}
	}
	t.Fatal("event stream ended")
	return nil
}

func receiver(t *testing.T, dir string) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { handleSend(w, r, dir) }))
	t.Cleanup(srv.Close)
	return srv
}

func TestReceiverTellsSubscribers(t *testing.T) {
	sc, _, path := subscribe(t)
	if runtime.GOOS != "windows" { // Windows has no Unix permission bits
		if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
			t.Fatalf("socket mode %v, want 0600", st.Mode().Perm())
		}
	}
	dir := t.TempDir()
	resp, err := http.Post(receiver(t, dir).URL+"/send?kind=file&name=a.txt&from=box&i=2&n=3", "", strings.NewReader("hello"))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("upload: %v %v", resp, err)
	}
	in, done := next(t, sc), next(t, sc)
	if in["event"] != "incoming" || in["name"] != "a.txt" || in["from"] != "box" || in["total"] != 5.0 ||
		in["index"] != 2.0 || in["count"] != 3.0 || in["ip"] != "127.0.0.1" {
		t.Fatalf("incoming = %v", in)
	}
	if done["event"] != "done" || done["saved"] != "a.txt" || done["path"] != filepath.Join(dir, "a.txt") || done["id"] != in["id"] {
		t.Fatalf("done = %v", done)
	}
}

func TestReceiverReportsProgress(t *testing.T) {
	sc, _, _ := subscribe(t)
	pr, pw := io.Pipe()
	go func() {
		// Two halves with a pause between, so at least one progress report falls in between.
		pw.Write(bytes.Repeat([]byte("x"), 1000))
		time.Sleep(200 * time.Millisecond)
		pw.Write(bytes.Repeat([]byte("x"), 1000))
		pw.Close()
	}()
	req, _ := http.NewRequest(http.MethodPost, receiver(t, t.TempDir()).URL+"/send?kind=file&name=b.bin", pr)
	req.ContentLength = 2000
	go http.DefaultClient.Do(req)
	var got []float64
	for sc.Scan() {
		var ev map[string]any
		json.Unmarshal(sc.Bytes(), &ev)
		if ev["event"] == "progress" {
			if ev["total"] != 2000.0 {
				t.Fatalf("progress total = %v", ev["total"])
			}
			got = append(got, ev["got"].(float64))
		}
		if ev["event"] == "done" {
			break
		}
	}
	if len(got) == 0 || got[0] < 1000 || got[0] > 2000 {
		t.Fatalf("progress reports %v", got)
	}
}

func TestFolderEventsUseSizeAndReportFailure(t *testing.T) {
	sc, _, _ := subscribe(t)
	dir := t.TempDir()
	// A folder streams without a length: the sender's size estimate stands in.
	req, _ := http.NewRequest(http.MethodPost, receiver(t, dir).URL+"/send?kind=dir&name=F&size=4096",
		io.MultiReader(strings.NewReader("not a tar archive at all"))) // hides the length, as a stream does
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("broken archive: %v %v", resp, err)
	}
	in, failed := next(t, sc), next(t, sc)
	if in["event"] != "incoming" || in["kind"] != "dir" || in["total"] != 4096.0 || in["index"] != nil {
		t.Fatalf("incoming = %v", in)
	}
	if failed["event"] != "failed" || failed["id"] != in["id"] {
		t.Fatalf("failed = %v", failed)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("left behind: %v", entries)
	}
}

func TestReceiverRefusesBadRequests(t *testing.T) {
	dir := t.TempDir()
	u := receiver(t, dir).URL
	if r, _ := http.Get(u + "/send?kind=file&name=a"); r.StatusCode != http.StatusNotFound {
		t.Fatalf("GET /send = %d", r.StatusCode)
	}
	for _, q := range []string{"kind=file&name=..", "kind=file&name=", "kind=exe&name=a", "kind=file&name=a&i=4&n=3"} {
		r, err := http.Post(u+"/send?"+q, "", strings.NewReader("x"))
		if err != nil {
			t.Fatal(err)
		}
		// A batch position that makes no sense is ignored, not refused.
		want := http.StatusBadRequest
		if strings.HasSuffix(q, "n=3") {
			want = http.StatusOK
		}
		if r.StatusCode != want {
			t.Fatalf("%s = %d, want %d", q, r.StatusCode, want)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Fatalf("Downloads holds %d entries, want only the valid upload", len(entries))
	}
}

func TestHubForgetsSubscribersThatLeave(t *testing.T) {
	_, c, _ := subscribe(t)
	c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for events.watched() {
		if time.Now().After(deadline) {
			t.Fatal("a closed subscriber still counts as watching")
		}
		time.Sleep(10 * time.Millisecond)
	}
	events.emit(map[string]any{"event": "progress"}) // must not block or panic
}

func TestSendAnnouncesBatchAndFolderSize(t *testing.T) {
	var queries []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries = append(queries, r.URL.RawQuery)
		io.Copy(io.Discard, r.Body)
		io.WriteString(w, r.URL.Query().Get("name"))
	}))
	defer srv.Close()
	host, p, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if p != strconv.Itoa(port) {
		// sendOne dials the lightdrop port; test the URL it builds through a client that redirects.
		http.DefaultClient.Transport = rewritePort{host + ":" + p}
		defer func() { http.DefaultClient.Transport = nil }()
	}
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "a.txt"), []byte("one"), 0o644)
	os.Mkdir(filepath.Join(src, "dir"), 0o755)
	os.WriteFile(filepath.Join(src, "dir", "b.txt"), []byte("two"), 0o644)
	jsonOut = true
	defer func() { jsonOut = false }()
	to := peer{Name: "box", IP: host}
	if err := sendOne(to, filepath.Join(src, "a.txt"), 1, 2); err != nil {
		t.Fatal(err)
	}
	if err := sendOne(to, filepath.Join(src, "dir"), 2, 2); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(queries[0], "i=1&n=2") || strings.Contains(queries[0], "size=") {
		t.Fatalf("file query %q", queries[0])
	}
	if !strings.Contains(queries[1], "kind=dir") || !strings.Contains(queries[1], "i=2&n=2") || !strings.Contains(queries[1], "&size=") {
		t.Fatalf("folder query %q", queries[1])
	}
}

// rewritePort sends every request to the test server instead of port 8765.
type rewritePort struct{ addr string }

func (r rewritePort) RoundTrip(req *http.Request) (*http.Response, error) {
	req.URL.Host = r.addr
	return http.DefaultTransport.RoundTrip(req)
}

func TestNotReceivingNamesPeopleOnly(t *testing.T) {
	if got := notReceiving(nil); got != "" {
		t.Fatalf("nobody idle: %q", got)
	}
	got := notReceiving([]peer{
		{Name: "nas", IP: "100.64.0.9"}, // a server: most never receive, not worth naming
		{Name: "ondejs-macbook-pro", IP: "100.64.0.2", Owner: "OrganTv12"},
		{Name: "laptop", IP: "100.64.0.3", Owner: "you"},
		{Name: "sams-iphone", IP: "100.64.0.4", Owner: "Sam", OS: "iOS"}, // lightdrop doesn't run on phones
		{Name: "studio", IP: "100.64.0.5", Owner: "Sam", OS: "macOS"},
	})
	want := "\n  online, not receiving: ondejs-macbook-pro (OrganTv12), studio (Sam)"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestUnknownOptionIsNotAMissingFile(t *testing.T) {
	err := sendAll("", []string{"--verbose"})
	if err == nil || !strings.Contains(err.Error(), "unknown option --verbose") {
		t.Fatalf("got %v", err)
	}
	err = sendAll("", []string{"no-such-file.txt"})
	if err == nil || !strings.Contains(err.Error(), "no such file or folder") {
		t.Fatalf("got %v", err)
	}
}
