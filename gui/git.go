package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Why the app looks at git at all
// ---------------------------------------------------------------------------
// The window is a launcher for build.sh, so "is there a newer version of the
// thing I am running" is a real question: an update can add a resource, fix a
// build rule or change config.env. The header used to say "working tree has
// uncommitted changes", which answers a question nobody asked — editing
// config.env is the point of the app. What it says now is whether a newer
// release exists, and what pulling one would do to the user's own edits.
//
// The danger the old label was hiding: `git pull` in a clone with local edits
// either refuses ("would be overwritten by merge") or, worse, conflicts inside
// config.env — which is sourced by bash, so conflict markers are not a
// cosmetic problem. So the update is split in two:
//
//	check  — fetch, count commits behind, and list which of those files the
//	         user has also edited (the "clash");
//	pull   — refuse when there is a clash, unless the caller asked to back the
//	         clashing files up first, in which case they are copied to
//	         backups/pre-update-<time>/ before being reset to HEAD.
//
// Nothing here runs on a timer the user cannot see: the window checks once at
// startup and then every ten minutes, all of it asynchronous.
type UpdateInfo struct {
	Checked   bool     `json:"checked"`
	Available bool     `json:"available"`
	Behind    int      `json:"behind"`
	Ahead     int      `json:"ahead"`
	Branch    string   `json:"branch"`
	Upstream  string   `json:"upstream"`
	Files     []string `json:"files"`
	Dirty     []string `json:"dirty"`
	Clash     []string `json:"clash"`
	// ConfigChanges is why config.env is special: it is a file the user is
	// expected to edit, so an update that rewrites it needs to say which
	// settings move, not just that the file changed.
	ConfigChanges []string `json:"configChanges"`
	CheckedAt     int64    `json:"checkedAt"`
	Error         string   `json:"error"`
}

// gitEnv keeps git from ever waiting for input: the app has no terminal, so a
// credential prompt would hang the check until the timeout with no hint why.
func gitEnv() []string {
	return append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=",
		"SSH_ASKPASS=",
		"GCM_INTERACTIVE=never",
	)
}

func gitRun(root string, timeout time.Duration, args ...string) (string, error) {
	if root == "" || !dirExists(filepath.Join(root, ".git")) {
		return "", errors.New("not a git checkout")
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", root}, args...)...)
	cmd.Env = gitEnv()
	cmd.Stdin = nil
	setProcAttr(cmd)
	out, err := cmd.CombinedOutput()
	// Only the line endings go: `git status --porcelain` puts meaning in a
	// leading space (" M file" is modified, "M  file" is staged), so trimming
	// the whole output would shift the first line and slice a character off the
	// first path.
	text := strings.TrimRight(string(out), "\r\n")
	if err != nil {
		if text == "" {
			text = err.Error()
		}
		return text, errors.New(text)
	}
	return text, nil
}

// gitInfo is best effort: a tarball unpack has no .git and that is fine.
func gitInfo(root string) (branch, commit string, dirty bool) {
	if root == "" || !dirExists(filepath.Join(root, ".git")) {
		return "", "", false
	}
	branch, _ = gitRun(root, 3*time.Second, "rev-parse", "--abbrev-ref", "HEAD")
	commit, _ = gitRun(root, 3*time.Second, "rev-parse", "--short", "HEAD")
	paths, _ := dirtyPaths(root)
	dirty = len(paths) > 0
	return branch, commit, dirty
}

// dirtyPaths is every path the working tree has changed, added or deleted —
// staged or not. The shape is "MM path" from --porcelain, one per line.
func dirtyPaths(root string) ([]string, error) {
	out, err := gitRun(root, 5*time.Second, "status", "--porcelain")
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(out, "\n") {
		if len(line) < 4 {
			continue
		}
		// Renames read "R  old -> new"; the new name is what a pull touches.
		path := strings.TrimSpace(line[3:])
		if i := strings.Index(path, " -> "); i >= 0 {
			path = path[i+4:]
		}
		path = strings.Trim(path, `"`)
		if path != "" {
			paths = append(paths, filepath.ToSlash(path))
		}
	}
	return paths, nil
}

// checkUpdate answers "is there something newer upstream, and would pulling it
// step on what I edited". It fetches, so it can be slow or fail offline; every
// caller must be able to live with Error being set.
func checkUpdate(root string) UpdateInfo {
	info := UpdateInfo{CheckedAt: time.Now().Unix()}
	if root == "" || !dirExists(filepath.Join(root, ".git")) {
		info.Error = "not a git checkout"
		return info
	}

	upstream, err := gitRun(root, 5*time.Second, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
	if err != nil || upstream == "" || upstream == "@{u}" {
		info.Error = "this branch has no upstream to compare against"
		return info
	}
	info.Upstream = upstream
	info.Branch, _ = gitRun(root, 5*time.Second, "rev-parse", "--abbrev-ref", "HEAD")

	if out, err := gitRun(root, 30*time.Second, "fetch", "--quiet", "--prune"); err != nil {
		info.Error = "could not reach the remote: " + firstLine(out)
		return info
	}

	counts, err := gitRun(root, 10*time.Second, "rev-list", "--left-right", "--count", "HEAD..."+upstream)
	if err != nil {
		info.Error = firstLine(counts)
		return info
	}
	fields := strings.Fields(counts)
	if len(fields) == 2 {
		// left = commits only HEAD has (ahead), right = only the upstream has.
		info.Ahead, _ = strconv.Atoi(fields[0])
		info.Behind, _ = strconv.Atoi(fields[1])
	}

	dirty, _ := dirtyPaths(root)
	info.Dirty = dirty

	if info.Behind > 0 {
		info.Available = true
		changed, err := gitRun(root, 15*time.Second, "diff", "--name-only", "HEAD.."+upstream)
		if err == nil {
			for _, line := range strings.Split(changed, "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					info.Files = append(info.Files, filepath.ToSlash(line))
				}
			}
		}
		info.Clash = intersect(info.Dirty, info.Files)
		for _, f := range info.Files {
			if f == "config.env" {
				info.ConfigChanges = configKeyDiff(root, upstream)
				break
			}
		}
	}

	info.Checked = true
	return info
}

// configKeyDiff lists the settings a config.env update rewrites, as the diff's
// own -/+ lines. Those are the values the user has to look at again after the
// pull, so they are worth showing before it happens.
func configKeyDiff(root, upstream string) []string {
	out, err := gitRun(root, 15*time.Second, "diff", "--unified=0", "HEAD.."+upstream, "--", "config.env")
	if err != nil {
		return nil
	}
	var changes []string
	for _, line := range strings.Split(out, "\n") {
		if len(line) == 0 {
			continue
		}
		sign := line[0]
		if sign != '-' && sign != '+' {
			continue
		}
		body := strings.TrimPrefix(line, string(sign))
		if strings.HasPrefix(body, "--") || strings.HasPrefix(body, "++") {
			continue
		}
		if configKey.FindStringSubmatch(body) == nil {
			continue
		}
		changes = append(changes, string(sign)+" "+strings.TrimSpace(body))
		if len(changes) >= 24 {
			changes = append(changes, "…")
			break
		}
	}
	return changes
}

func intersect(a, b []string) []string {
	set := make(map[string]struct{}, len(b))
	for _, s := range b {
		set[s] = struct{}{}
	}
	var both []string
	for _, s := range a {
		if _, ok := set[s]; ok {
			both = append(both, s)
		}
	}
	return both
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

// ---------------------------------------------------------------------------
// Pulling
// ---------------------------------------------------------------------------
// pullResult is what the dialog shows after the attempt, including the reason
// when there is nothing to show but an error.
type pullResult struct {
	Output   string   `json:"output"`
	BackedUp []string `json:"backedUp"`
	Changed  []string `json:"changed"`
	Restart  bool     `json:"restart"`
}

// errClash is returned when pulling would overwrite local edits and the caller
// did not agree to back them up first. The caller turns it into the dialog that
// lists the files; it is not a crash.
var errClash = errors.New("local changes would be overwritten")

// pullUpdate fast-forwards the clone to its upstream.
//
// backupClash is the user's answer to the dialog: copy my versions of the
// files that would be overwritten into backups/, then let git replace them. Any
// edit that does not collide survives untouched — a plain `git pull --ff-only`
// keeps those, which is why this is not implemented as a stash.
func (a *App) pullUpdate(backupClash bool) (pullResult, error) {
	var res pullResult
	root := a.Root()
	if root == "" {
		return res, errors.New("no clone selected")
	}

	info := checkUpdate(root)
	if info.Error != "" {
		return res, errors.New(info.Error)
	}
	if !info.Available {
		return res, errors.New("already up to date")
	}
	if len(info.Clash) > 0 && !backupClash {
		return res, fmt.Errorf("%w: %s", errClash, strings.Join(info.Clash, ", "))
	}

	for _, rel := range info.Clash {
		saved, err := backupPath(root, rel)
		if err != nil {
			return res, err
		}
		res.BackedUp = append(res.BackedUp, saved)
		// Tracked: go back to the committed version so the pull can land.
		// Untracked: a pull would simply refuse, so move it aside (it is in
		// backups/ now) — otherwise the update can never be applied.
		if _, err := gitRun(root, 10*time.Second, "ls-files", "--error-unmatch", rel); err == nil {
			if out, err := gitRun(root, 10*time.Second, "checkout", "HEAD", "--", rel); err != nil {
				return res, fmt.Errorf("could not reset %s: %s", rel, firstLine(out))
			}
		} else if err := os.Remove(filepath.Join(root, filepath.FromSlash(rel))); err != nil && !os.IsNotExist(err) {
			return res, fmt.Errorf("could not move %s aside: %w", rel, err)
		}
	}

	out, err := gitRun(root, 120*time.Second, "pull", "--ff-only")
	res.Output = out
	// A pull that printed conflict text is a failure even if git's exit code
	// says otherwise; --ff-only makes that unlikely, but not impossible when a
	// patch was applied by the remote.
	if err != nil {
		return res, errors.New(firstLine(out))
	}

	res.Changed = info.Files
	for _, f := range res.Changed {
		if strings.HasPrefix(f, "gui/") || f == "go.mod" || f == "go.sum" {
			// The running binary is the old one; build.sh itself is read fresh
			// from disk on the next run, so only the window has to restart.
			res.Restart = true
		}
	}

	a.invalidateUpdate()
	return res, nil
}

// backupPath copies one file from the clone into backups/pre-update-<time>/,
// keeping its relative path so two files with the same name cannot collide.
func backupPath(root, rel string) (string, error) {
	src := filepath.Join(root, filepath.FromSlash(rel))
	stamp := time.Now().Format("2006-01-02-150405")
	dst := filepath.Join(root, "backups", "pre-update-"+stamp, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	if err := copyFile(src, dst); err != nil {
		return "", fmt.Errorf("could not back up %s: %w", rel, err)
	}
	return filepath.ToSlash(filepath.Join("backups", "pre-update-"+stamp, filepath.FromSlash(rel))), nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
