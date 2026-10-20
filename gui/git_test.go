package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// A throwaway upstream + clone
// ---------------------------------------------------------------------------
// These tests run real git against a bare repository in a temp directory. That
// is the only way to be sure about the part that actually matters: whether
// `pull --ff-only` after backing up the clash leaves the user with the upstream
// files and their own copy somewhere safe.
type repo struct {
	t    *testing.T
	base string
	bare string
	seed string // the "author" clone the upstream commits come from
	work string // the clone under test
}

func newRepo(t *testing.T) *repo {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	r := &repo{t: t, base: t.TempDir()}
	r.bare = filepath.Join(r.base, "upstream.git")
	r.seed = filepath.Join(r.base, "seed")
	r.work = filepath.Join(r.base, "work")

	r.git(r.base, "init", "--bare", "-q", r.bare)
	r.git(r.base, "init", "-q", r.seed)
	r.git(r.seed, "config", "user.email", "test@example.com")
	r.git(r.seed, "config", "user.name", "test")
	r.git(r.seed, "config", "core.autocrlf", "false")
	r.git(r.seed, "symbolic-ref", "HEAD", "refs/heads/main")

	r.write("seed", "build.sh", "#!/bin/sh\necho build\n")
	r.write("seed", filepath.Join("scripts", "common.sh"), "# helpers\n")
	r.write("seed", "config.env", "DEVICE_CODENAME=\"old\"\nSTATUS_BAR_HEIGHT=000\n")
	r.write("seed", "README.md", "readme\n")
	r.git(r.seed, "add", "-A")
	r.git(r.seed, "commit", "-qm", "initial")
	r.git(r.seed, "remote", "add", "origin", r.bare)
	r.git(r.seed, "push", "-q", "-u", "origin", "main")
	// A bare repo made by `git init` still points HEAD at refs/heads/master, so
	// a clone of it checks nothing out and has no upstream to compare with.
	r.git(r.bare, "symbolic-ref", "HEAD", "refs/heads/main")

	// core.autocrlf=false on the clone itself: Git for Windows defaults it to
	// true, and a checkout that converts line endings would make every file in
	// the fresh clone look locally modified.
	r.git(r.base, "-c", "core.autocrlf=false", "clone", "-q", r.bare, r.work)
	r.git(r.work, "config", "user.email", "test@example.com")
	r.git(r.work, "config", "user.name", "test")
	r.git(r.work, "config", "core.autocrlf", "false")
	return r
}

func (r *repo) git(dir string, args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func (r *repo) write(where, rel, body string) {
	r.t.Helper()
	dir := r.seed
	if where == "work" {
		dir = r.work
	}
	path := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

func (r *repo) publish(rel, body string) {
	r.t.Helper()
	r.write("seed", rel, body)
	r.git(r.seed, "add", "-A")
	r.git(r.seed, "commit", "-qm", "update "+rel)
	r.git(r.seed, "push", "-q", "origin", "main")
}

func TestIntersect(t *testing.T) {
	got := intersect([]string{"a", "b", "c"}, []string{"c", "d", "a"})
	if strings.Join(got, ",") != "a,c" {
		t.Fatalf("intersect = %q, want a,c", got)
	}
	if len(intersect(nil, []string{"a"})) != 0 {
		t.Fatal("an empty side produced a clash")
	}
}

func TestCheckUpdateReportsWhatChanged(t *testing.T) {
	r := newRepo(t)
	r.publish("config.env", "DEVICE_CODENAME=\"new\"\nSTATUS_BAR_HEIGHT=76\n")

	info := checkUpdate(r.work)
	if info.Error != "" {
		t.Fatalf("check failed: %s", info.Error)
	}
	if !info.Available || info.Behind != 1 {
		t.Fatalf("available=%v behind=%d, want available and 1", info.Available, info.Behind)
	}
	if info.Upstream != "origin/main" {
		t.Fatalf("upstream = %q", info.Upstream)
	}
	if strings.Join(info.Files, ",") != "config.env" {
		t.Fatalf("files = %q, want config.env", info.Files)
	}
	// The user has not touched anything, so nothing clashes.
	if len(info.Clash) != 0 {
		t.Fatalf("clash = %q, want none", info.Clash)
	}
	// config.env is the file people edit, so the dialog has to name the keys.
	joined := strings.Join(info.ConfigChanges, "\n")
	if !strings.Contains(joined, "STATUS_BAR_HEIGHT") {
		t.Fatalf("configChanges did not name the settings: %q", info.ConfigChanges)
	}
}

func TestCheckUpdateSeesLocalEditsAsAClash(t *testing.T) {
	r := newRepo(t)
	r.publish("config.env", "DEVICE_CODENAME=\"new\"\nSTATUS_BAR_HEIGHT=76\n")
	r.write("work", "config.env", "DEVICE_CODENAME=\"mine\"\nSTATUS_BAR_HEIGHT=000\n")

	info := checkUpdate(r.work)
	if len(info.Dirty) != 1 || info.Dirty[0] != "config.env" {
		t.Fatalf("dirty = %q", info.Dirty)
	}
	if len(info.Clash) != 1 || info.Clash[0] != "config.env" {
		t.Fatalf("clash = %q, want config.env", info.Clash)
	}
}

// TestPullRefusesThenBacksUp is the behaviour that protects an editor's
// config.env: the first pull is refused with the clash, and the second one
// saves the user's version before git replaces it.
func TestPullRefusesThenBacksUp(t *testing.T) {
	r := newRepo(t)
	r.publish("config.env", "DEVICE_CODENAME=\"new\"\nSTATUS_BAR_HEIGHT=76\n")
	r.write("work", "config.env", "DEVICE_CODENAME=\"mine\"\nSTATUS_BAR_HEIGHT=000\n")

	app := &App{runner: NewRunner(), root: r.work}

	if _, err := app.pullUpdate(false); err == nil {
		t.Fatal("a pull that would overwrite a local edit was allowed")
	} else if !strings.Contains(err.Error(), "config.env") {
		t.Fatalf("the refusal did not name the file: %v", err)
	}

	res, err := app.pullUpdate(true)
	if err != nil {
		t.Fatalf("backup-and-pull failed: %v", err)
	}
	if len(res.BackedUp) != 1 {
		t.Fatalf("backedUp = %q", res.BackedUp)
	}

	saved, err := os.ReadFile(filepath.Join(r.work, filepath.FromSlash(res.BackedUp[0])))
	if err != nil {
		t.Fatalf("the backup is not on disk: %v", err)
	}
	if !strings.Contains(string(saved), `DEVICE_CODENAME="mine"`) {
		t.Fatalf("the backup does not hold the user's version:\n%s", saved)
	}

	now, err := os.ReadFile(filepath.Join(r.work, "config.env"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(now), `DEVICE_CODENAME="new"`) {
		t.Fatalf("the pull did not land the upstream file:\n%s", now)
	}

	// And a second pull has nothing left to do.
	if _, err := app.pullUpdate(false); err == nil {
		t.Fatal("pulling again should say there is nothing to do")
	}
}

// TestPullKeepsUnrelatedEdits: a backup must not be an excuse to throw away
// work on a file the update does not touch.
func TestPullKeepsUnrelatedEdits(t *testing.T) {
	r := newRepo(t)
	r.publish("README.md", "readme v2\n")
	r.write("work", "notes.txt", "my notes\n")

	app := &App{runner: NewRunner(), root: r.work}
	if _, err := app.pullUpdate(false); err != nil {
		t.Fatalf("pull with an unrelated untracked file failed: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(r.work, "notes.txt")); err != nil || string(b) != "my notes\n" {
		t.Fatalf("an unrelated file was touched: %v %q", err, b)
	}
}

func TestPullWithoutUpstreamExplainsItself(t *testing.T) {
	dir := t.TempDir()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	cmd := exec.Command("git", "-C", dir, "init", "-q")
	if err := cmd.Run(); err != nil {
		t.Skipf("git init failed: %v", err)
	}
	info := checkUpdate(dir)
	if info.Available {
		t.Fatal("a repository with no commits reported an update")
	}
	if info.Error == "" {
		t.Fatal("no upstream should be explained, not silently ignored")
	}
}

func TestGitInfoOutsideAClone(t *testing.T) {
	if branch, commit, dirty := gitInfo(t.TempDir()); branch != "" || commit != "" || dirty {
		t.Fatalf("a plain folder reported %q %q %v", branch, commit, dirty)
	}
}
