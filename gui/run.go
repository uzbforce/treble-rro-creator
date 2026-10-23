package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// LogLine is one line of child output as it reaches the pane.
//
// Stream is "out", "err", "note" (something the GUI says), "progress" (a
// repaint of the line before it, sent with \r) or "done" (the last line of a
// run, which also unblocks the UI's spinner).
type LogLine struct {
	Seq    int    `json:"seq"`
	Stream string `json:"stream"`
	Text   string `json:"text"`
}

// RunState is what a freshly opened window needs to redraw the pane: a run may
// still be going when the page reloads, so the buffer is replayed from here
// instead of starting empty.
type RunState struct {
	Running bool      `json:"running"`
	Label   string    `json:"label"`
	Exit    int       `json:"exit"`
	Lines   []LogLine `json:"lines"`
	// Sudo: the run stopped because installing the build tools needs a
	// password, and the app is the only thing that can ask for it.
	Sudo bool `json:"sudo"`
}

// Gate is the process-wide "one job at a time" token.
//
// The Build and the Device console each own a Runner, so an adb command's
// output can never land in the build log again. They share one Gate because
// they also share the clone: an adb pull writing stuff/tools/framework-res.apk while
// a build reads it is still one job too many.
type Gate struct{ ch chan struct{} }

func NewGate() *Gate { return &Gate{ch: make(chan struct{}, 1)} }

// tryAcquire takes the slot without waiting: a second job is an error to
// report, not something to queue behind a build that may take minutes.
func (g *Gate) tryAcquire() bool {
	select {
	case g.ch <- struct{}{}:
		return true
	default:
		return false
	}
}

func (g *Gate) release() {
	select {
	case <-g.ch:
	default:
	}
}

// Runner owns one console: the child process it is running, that run's log
// ring buffer, and the subscribers to it.
//
// One job at a time is deliberate: build.sh writes to out/ and src/staging, and
// a second run started mid-build would corrupt both. The mutex plus `running`
// makes "Start while running" an error rather than a race.
type Runner struct {
	mu       sync.Mutex
	running  bool
	label    string
	exit     int
	seq      int
	lines    []LogLine
	subs     map[chan LogLine]struct{}
	cmd      *exec.Cmd
	maxLines int
	started  time.Time
	gate     *Gate
	// Set when the child asked for a sudo password; finish turns it into the
	// line that opens the app's dialog. cleanup removes the password file.
	sudoNeeded bool
	cleanup    func()
}

// NewRunner makes a console. A Runner given no Gate gets one of its own, which
// is all a test needs; the app passes the same Gate to both consoles.
func NewRunner(gates ...*Gate) *Runner {
	gate := NewGate()
	if len(gates) > 0 && gates[0] != nil {
		gate = gates[0]
	}
	return &Runner{maxLines: 20000, subs: make(map[chan LogLine]struct{}), gate: gate}
}

// Start launches a program in the clone and begins streaming its output.
//
// mergeStderr is for tools that report progress on stderr — adb pull does — so
// a successful pull is not painted in the pane's error colour. The exit code,
// not the stream, decides whether the run succeeded.
func (r *Runner) Start(root, program string, args []string, label string, mergeStderr bool) error {
	return r.start(root, program, args, label, mergeStderr, nil, nil)
}

// StartEnv is Start with extra environment entries and a cleanup that runs when
// the job ends. The sudo handshake uses both: the page's password goes into a
// private file, the file's path into the environment for sudo -A, and the file
// must be gone the moment the child is.
func (r *Runner) StartEnv(root, program string, args []string, label string, mergeStderr bool, extraEnv []string, cleanup func()) error {
	return r.start(root, program, args, label, mergeStderr, extraEnv, cleanup)
}

func (r *Runner) start(root, program string, args []string, label string, mergeStderr bool, extraEnv []string, cleanup func()) error {
	abort := func() {
		if cleanup != nil {
			cleanup()
		}
	}
	if !dirExists(root) {
		abort()
		return errors.New("no clone selected — pick the folder that has build.sh")
	}
	if program == "" {
		abort()
		return errors.New("no bash found — install Git for Windows, or set the bash path")
	}

	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		abort()
		return errors.New("a command is already running")
	}
	if !r.gate.tryAcquire() {
		r.mu.Unlock()
		abort()
		return errors.New("a command is already running")
	}
	// A new run starts a new log: the pane means "what just happened", not
	// history. The clone keeps its own logs on disk if something needs to be
	// kept.
	r.lines = nil
	r.seq = 0
	r.exit = 0
	r.sudoNeeded = false
	r.cleanup = cleanup
	r.label = label
	r.running = true
	r.started = time.Now()
	r.mu.Unlock()

	cmd := exec.Command(program, args...)
	cmd.Dir = root
	// The scripts colour their output with tput/ANSI; the pane renders SGR, so
	// ask for a colour-capable terminal instead of inheriting whatever the app
	// was started from.
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	cmd.Env = mergeEnv(cmd.Env, extraEnv)
	// No stdin: anything that would prompt has to take its default. That is
	// what the -y appended in buildArgs is for.
	cmd.Stdin = nil
	setProcAttr(cmd)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		r.finish(err)
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		r.finish(err)
		return err
	}
	if err := cmd.Start(); err != nil {
		r.finish(err)
		return fmt.Errorf("could not start %s: %w", filepath.Base(program), err)
	}

	r.mu.Lock()
	r.cmd = cmd
	r.mu.Unlock()

	r.emit("note", label)

	// Wait for both pipes to hit EOF before reaping, otherwise the tail of a
	// build is cut off exactly when the interesting error appears.
	errStream := "err"
	if mergeStderr {
		errStream = "out"
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go r.pump(stdout, "out", &wg)
	go r.pump(stderr, errStream, &wg)
	go func() {
		wg.Wait()
		r.finish(cmd.Wait())
	}()
	return nil
}

// pump streams one pipe line by line. A bare carriage return ends a line too:
// pacman and adb pull repaint a progress bar with \r between newlines, and
// waiting for the next \n would hide the whole download until it finished.
func (r *Runner) pump(pipe io.Reader, stream string, wg *sync.WaitGroup) {
	defer wg.Done()
	br := bufio.NewReader(pipe)
	buf := make([]byte, 0, 512)
	flush := func(progress bool) {
		text := string(buf)
		buf = buf[:0]
		if !progress {
			r.emit(stream, text)
			return
		}
		// An empty repaint would only blank the previous one.
		if text != "" {
			r.emit("progress", text)
		}
	}
	for {
		b, err := br.ReadByte()
		if err != nil {
			if len(buf) > 0 {
				flush(false)
			}
			return
		}
		switch b {
		case '\n':
			flush(false)
		case '\r':
			// CRLF is an ordinary line ending; a lone CR is a repaint.
			if next, err := br.Peek(1); err == nil && next[0] == '\n' {
				_, _ = br.ReadByte()
				flush(false)
			} else {
				flush(true)
			}
		default:
			buf = append(buf, b)
			// A line is text; this only stops an endless one from growing.
			if len(buf) >= 64*1024 {
				flush(false)
			}
		}
	}
}

// sudoMarker is the one line stuff/scripts/toolchain.sh prints when it could
// install the build tools if only something could ask for a password. It is a
// protocol line, not a message: the human sentence comes right after it.
const sudoMarker = "@@RRO_SUDO_REQUIRED@@"

// mergeEnv appends entries, dropping any earlier value for the same key: the
// child's getenv sees the first copy, so leaving both would make the override
// depend on whether the app itself was started with SUDO_ASKPASS set.
func mergeEnv(env, extra []string) []string {
	if len(extra) == 0 {
		return env
	}
	drop := make(map[string]bool, len(extra))
	for _, e := range extra {
		if key, _, ok := strings.Cut(e, "="); ok {
			drop[key] = true
		}
	}
	kept := env[:0]
	for _, e := range env {
		if key, _, ok := strings.Cut(e, "="); ok && drop[key] {
			continue
		}
		kept = append(kept, e)
	}
	return append(kept, extra...)
}

func (r *Runner) emit(stream, text string) {
	if strings.TrimSpace(text) == sudoMarker {
		r.mu.Lock()
		r.sudoNeeded = true
		r.mu.Unlock()
		stream = "note"
		text = "installing the build tools needs root — the app can ask for the password"
	}

	r.mu.Lock()
	r.seq++
	line := LogLine{Seq: r.seq, Stream: stream, Text: text}
	// A progress repaint replaces the previous one in the buffer: every update
	// still reaches the live page, but a replayed hundred-step download bar is
	// one line instead of a hundred. The page draws it in place either way.
	if stream == "progress" && len(r.lines) > 0 && r.lines[len(r.lines)-1].Stream == "progress" {
		r.lines[len(r.lines)-1] = line
	} else {
		r.lines = append(r.lines, line)
		if len(r.lines) > r.maxLines {
			kept := make([]LogLine, r.maxLines)
			copy(kept, r.lines[len(r.lines)-r.maxLines:])
			r.lines = kept
		}
	}
	for ch := range r.subs {
		// A window that is not reading must not stall the build.
		select {
		case ch <- line:
		default:
		}
	}
	r.mu.Unlock()
}

func (r *Runner) finish(err error) {
	r.gate.release()

	code := 0
	if err != nil {
		code = -1
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		}
	}

	r.mu.Lock()
	r.running = false
	r.cmd = nil
	r.exit = code
	needSudo := r.sudoNeeded && code != 0
	cleanup := r.cleanup
	r.cleanup = nil
	r.mu.Unlock()

	// The password file only ever existed for the child's lifetime.
	if cleanup != nil {
		cleanup()
	}

	if needSudo {
		// Its own stream: the page turns this into the password dialog. The
		// run is already over, so the retry cannot collide with it.
		r.emit("sudo", "sudo password needed")
	}

	switch {
	case code == 0:
		r.emit("done", "finished")
	case code < 0:
		r.emit("done", "could not run")
	default:
		r.emit("done", fmt.Sprintf("exited with code %d", code))
	}
}

// Begin reserves the pane for work this program does itself.
//
// The only such job is downloading platform-tools (see adb.go): it must not
// fight a build for out/, and it has progress worth showing, but there is no
// child process to stream. It takes the same "one job at a time" slot so the
// two can never overlap, and FinishJob closes it the same way a child does.
func (r *Runner) Begin(label string) error {
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return errors.New("a command is already running")
	}
	if !r.gate.tryAcquire() {
		r.mu.Unlock()
		return errors.New("a command is already running")
	}
	r.lines = nil
	r.seq = 0
	r.exit = 0
	r.sudoNeeded = false
	r.label = label
	r.running = true
	r.started = time.Now()
	r.mu.Unlock()

	// emit takes the same mutex, so it has to happen after the unlock.
	r.emit("note", label)
	return nil
}

// Note writes a progress line for a job started with Begin.
func (r *Runner) Note(text string) { r.emit("out", text) }

// FinishJob ends a job started with Begin. err is printed before the closing
// line, so the pane never says a job failed without saying why.
func (r *Runner) FinishJob(err error) {
	r.gate.release()

	code := 0
	if err != nil {
		code = 1
		r.emit("err", err.Error())
	}

	r.mu.Lock()
	r.running = false
	r.cmd = nil
	r.exit = code
	r.mu.Unlock()

	if code == 0 {
		r.emit("done", "finished")
	} else {
		r.emit("done", "exited with code 1")
	}
}

func (r *Runner) Snapshot() RunState {
	r.mu.Lock()
	defer r.mu.Unlock()
	return RunState{
		Running: r.running,
		Label:   r.label,
		Exit:    r.exit,
		Sudo:    r.sudoNeeded,
		// Non-nil so an empty buffer encodes as [] rather than null.
		Lines: append([]LogLine{}, r.lines...),
	}
}

// Subscribe returns a channel of new lines and a function that stops it.
//
// The channel is never closed: emit holds the same mutex and a close would race
// with a send. Subscribers stop on their own context instead.
func (r *Runner) Subscribe() (<-chan LogLine, func()) {
	ch := make(chan LogLine, 256)
	r.mu.Lock()
	r.subs[ch] = struct{}{}
	r.mu.Unlock()
	return ch, func() {
		r.mu.Lock()
		delete(r.subs, ch)
		r.mu.Unlock()
	}
}

// Cancel stops the running command and everything it spawned. Killing only
// bash would leave aapt2 compiling with its output redirected into a file
// nobody is watching.
func (r *Runner) Cancel() error {
	r.mu.Lock()
	cmd := r.cmd
	running := r.running
	r.mu.Unlock()

	if !running || cmd == nil {
		return nil
	}
	r.emit("note", "stopping…")
	if err := killTree(cmd); err != nil {
		r.emit("err", err.Error())
		return err
	}
	return nil
}
