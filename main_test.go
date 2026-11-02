package main

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
