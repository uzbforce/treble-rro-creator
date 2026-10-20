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
// Stream is "out", "err", "note" (something the GUI says) or "done" (the last
// line of a run, which also unblocks the UI's spinner).
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
}

// Runner owns the single child process the app is allowed to have.
//
// One at a time is deliberate: build.sh writes to out/ and src/staging, and a
// second run started mid-build would corrupt both. The mutex plus `running`
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
}

func NewRunner() *Runner {
	return &Runner{maxLines: 20000, subs: make(map[chan LogLine]struct{})}
}

// Start launches a program in the clone and begins streaming its output.
//
// mergeStderr is for tools that report progress on stderr — adb pull does — so
// a successful pull is not painted in the pane's error colour. The exit code,
// not the stream, decides whether the run succeeded.
func (r *Runner) Start(root, program string, args []string, label string, mergeStderr bool) error {
	if !dirExists(root) {
		return errors.New("no clone selected — pick the folder that has build.sh")
	}
	if program == "" {
		return errors.New("no bash found — install Git for Windows, or set the bash path")
	}

	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return errors.New("a command is already running")
	}
	// A new run starts a new log: the pane means "what just happened", not
	// history. The clone keeps its own logs on disk if something needs to be
	// kept.
	r.lines = nil
	r.seq = 0
	r.exit = 0
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

func (r *Runner) pump(pipe io.Reader, stream string, wg *sync.WaitGroup) {
	defer wg.Done()
	br := bufio.NewReader(pipe)
	for {
		line, err := br.ReadString('\n')
		if line != "" {
			r.emit(stream, strings.TrimRight(line, "\r\n"))
		}
		if err != nil {
			return
		}
	}
}

func (r *Runner) emit(stream, text string) {
	r.mu.Lock()
	r.seq++
	line := LogLine{Seq: r.seq, Stream: stream, Text: text}
	r.lines = append(r.lines, line)
	if len(r.lines) > r.maxLines {
		kept := make([]LogLine, r.maxLines)
		copy(kept, r.lines[len(r.lines)-r.maxLines:])
		r.lines = kept
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
	r.mu.Unlock()

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
	r.lines = nil
	r.seq = 0
	r.exit = 0
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
