package main

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// power_profile.xml
// ---------------------------------------------------------------------------
// `aapt2 dump xmltree` prints a compiled XML file as an indented tree:
//
//	E: device (line=20)
//	  A: name="Android" (Raw: "Android")
//	    E: item (line=38)
//	      A: name="ambient.on.display0" (Raw: "ambient.on.display0")
//	        T: '0.1'
//
// That is not XML, and apktool is not a dependency of this project, so the tree
// is turned back into a file here. The device-probe script prints the tree (and
// a `# source:` line); this is the only place that knows how to read it, and it
// is tested against the real output of a phone's framework-res.apk.
//
// Saving writes src/framework/res/xml/power_profile.xml — the file the build
// already compiles into the overlay — after checking that the text is
// well-formed XML with a <device> root and at least one item.

type xmlNode struct {
	name  string
	attrs [][2]string
	text  string
	kids  []*xmlNode
}

type PowerProfile struct {
	XML    string `json:"xml"`
	Source string `json:"source"`
	Items  int    `json:"items"`
}

// runPowerProfile asks the script for the tree. It returns the raw tree and the
// APK it came from.
func (a *App) runPowerProfile(mode, dir, serial string) (PowerProfile, string, error) {
	root := a.Root()
	if !isClone(root) {
		return PowerProfile{}, "", errors.New("no clone selected — pick the folder that has build.sh")
	}
	script := a.detectScript()
	if !fileExists(script) {
		return PowerProfile{}, "", errors.New("stuff/scripts/device-probe.sh is missing — update the clone")
	}
	bash := a.Bash()
	if bash == "" {
		return PowerProfile{}, "", errors.New("no bash found — install Git for Windows, or set the bash path")
	}

	args := []string{"--noprofile", "--norc", script, "--power-profile"}
	if mode == "firmware" {
		args = append(args, "--firmware", dir)
	} else if serial != "" {
		args = append(args, "--device", serial)
	}
	timeout := 3 * time.Minute
	if mode == "firmware" {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, bash, args...)
	cmd.Dir = root
	env := append(os.Environ(), "TERM=dumb")
	if adb := a.adbPath(); adb != "" {
		env = append(env, "ADB="+adb)
	}
	if aapt2 := a.aapt2Path(); aapt2 != "" {
		env = append(env, "AAPT2="+aapt2)
	}
	cmd.Env = env

	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	log := strings.TrimSpace(stderr.String())

	if ctx.Err() == context.DeadlineExceeded {
		return PowerProfile{}, log, fmt.Errorf("reading the power profile took longer than %s and was stopped", timeout)
	}
	if err != nil {
		msg := log
		if msg == "" {
			msg = err.Error()
		}
		return PowerProfile{}, log, errors.New(msg)
	}

	source := ""
	lines := strings.Split(strings.ReplaceAll(string(out), "\r\n", "\n"), "\n")
	tree := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(line, "# source: ") {
			source = strings.TrimSpace(strings.TrimPrefix(line, "# source: "))
			continue
		}
		if strings.HasPrefix(line, "#") {
			continue
		}
		tree = append(tree, line)
	}

	body, items, err := xmltreeToXML(strings.Join(tree, "\n"))
	if err != nil {
		return PowerProfile{}, log, err
	}
	return PowerProfile{XML: body, Source: source, Items: items}, log, nil
}

// xmltreeToXML converts the aapt2 tree into a document. The root element is
// part of the tree (aapt2 prints it), so nothing is invented here.
func xmltreeToXML(tree string) (string, int, error) {
	var root *xmlNode
	var stack []*xmlNode
	namespaces := map[string]string{}
	items := 0

	lines := strings.Split(strings.ReplaceAll(tree, "\r\n", "\n"), "\n")
	for n, raw := range lines {
		line := strings.TrimRight(raw, " \t")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		// aapt2 indents an element by 4 spaces per nesting level and hangs its
		// attributes and text one half-level (2 spaces) below it, so the nesting
		// depth is indent/4, not indent/2.
		indent := len(line) - len(strings.TrimLeft(line, " "))
		depth := indent / 4

		switch {
		case strings.HasPrefix(trimmed, "N: "):
			// N: android=http://schemas.android.com/apk/res/android
			body := strings.TrimPrefix(trimmed, "N: ")
			if eq := strings.IndexByte(body, '='); eq > 0 {
				namespaces[strings.TrimSpace(body[eq+1:])] = strings.TrimSpace(body[:eq])
			}

		case strings.HasPrefix(trimmed, "E: "):
			body := strings.TrimPrefix(trimmed, "E: ")
			if i := strings.Index(body, " (line="); i >= 0 {
				body = body[:i]
			}
			node := &xmlNode{name: strings.TrimSpace(body)}
			if node.name == "" {
				return "", 0, fmt.Errorf("line %d: element without a name", n+1)
			}
			for len(stack) > depth {
				stack = stack[:len(stack)-1]
			}
			if len(stack) == 0 {
				if root != nil {
					return "", 0, fmt.Errorf("line %d: a second root element (%s)", n+1, node.name)
				}
				root = node
			} else {
				parent := stack[len(stack)-1]
				parent.kids = append(parent.kids, node)
			}
			stack = append(stack, node)
			if node.name == "item" || node.name == "array" {
				items++
			}

		case strings.HasPrefix(trimmed, "A: "):
			if len(stack) == 0 {
				return "", 0, fmt.Errorf("line %d: an attribute before any element", n+1)
			}
			key, value, err := parseTreeAttr(strings.TrimPrefix(trimmed, "A: "), namespaces)
			if err != nil {
				return "", 0, fmt.Errorf("line %d: %w", n+1, err)
			}
			stack[len(stack)-1].attrs = append(stack[len(stack)-1].attrs, [2]string{key, value})

		case strings.HasPrefix(trimmed, "T: "):
			if len(stack) == 0 {
				return "", 0, fmt.Errorf("line %d: text before any element", n+1)
			}
			stack[len(stack)-1].text += strings.TrimSuffix(strings.TrimPrefix(strings.TrimPrefix(trimmed, "T: "), "'"), "'")

		default:
			// aapt2 has other line kinds (e.g. "W:" warnings); they are not
			// part of the document and are ignored rather than guessed at.
			continue
		}
	}

	if root == nil {
		return "", 0, errors.New("the tree has no root element")
	}
	if root.name != "device" && root.name != "power_profile" {
		return "", 0, fmt.Errorf("the root is <%s>, not a power profile", root.name)
	}
	if items == 0 {
		return "", 0, errors.New("the profile has no <item> or <array> entries")
	}

	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString("<!-- Extracted from the stock firmware by the Detect tab. The build compiles\n")
	b.WriteString("     this file into the overlay as res/xml/power_profile.xml. -->\n")
	writeNode(&b, root, 0)

	body := b.String()
	// Refuse anything that would fail to compile: a well-formed document with a
	// power-profile root is the contract, and it is cheap to check here.
	var probe struct {
		XMLName xml.Name
	}
	if err := xml.Unmarshal([]byte(body), &probe); err != nil {
		return "", 0, fmt.Errorf("the converted profile is not valid XML: %w", err)
	}
	return body, items, nil
}

func parseTreeAttr(raw string, namespaces map[string]string) (string, string, error) {
	eq := strings.IndexByte(raw, '=')
	if eq < 0 {
		return "", "", fmt.Errorf("attribute without a value: %q", raw)
	}
	key := strings.TrimSpace(raw[:eq])
	value := strings.TrimSpace(raw[eq+1:])

	// Namespaced attributes print as the full URI plus the resource id:
	//   http://schemas.android.com/apk/res/android:sharedUserId(0x0101000b)
	if i := strings.Index(key, "(0x"); i >= 0 {
		key = key[:i]
	}
	for uri, prefix := range namespaces {
		if strings.HasPrefix(key, uri+":") {
			key = prefix + ":" + strings.TrimPrefix(key, uri+":")
			break
		}
	}
	if strings.Contains(key, "/") {
		return "", "", fmt.Errorf("attribute %q has an unrecognised name", key)
	}

	switch {
	case strings.HasPrefix(value, `"`):
		// A quoted value may be followed by " (Raw: "...")" or a resource id.
		end := -1
		for i := 1; i < len(value); i++ {
			if value[i] == '"' && value[i-1] != '\\' {
				end = i
				break
			}
		}
		if end < 0 {
			return "", "", fmt.Errorf("attribute %s has an unterminated string", key)
		}
		text := value[1:end]
		text = strings.ReplaceAll(text, `\"`, `"`)
		text = strings.ReplaceAll(text, `\\`, `\`)
		return key, text, nil

	case strings.HasPrefix(value, "@"):
		return "", "", fmt.Errorf("attribute %s points at a resource (%s); aapt2 cannot resolve it without the resource table", key, strings.Fields(value)[0])
	}

	// Numbers, booleans and enums print as a bare token; anything after it is
	// a note about the compiled form.
	return key, strings.Fields(value)[0], nil
}

func writeNode(b *strings.Builder, n *xmlNode, depth int) {
	indent := strings.Repeat("    ", depth)
	b.WriteString(indent + "<" + n.name)
	for _, a := range n.attrs {
		b.WriteString(" " + a[0] + `="` + escapeXML(a[1]) + `"`)
	}
	if len(n.kids) == 0 && n.text == "" {
		b.WriteString("/>\n")
		return
	}
	b.WriteString(">")
	if len(n.kids) == 0 {
		b.WriteString(escapeXML(n.text))
		b.WriteString("</" + n.name + ">\n")
		return
	}
	b.WriteString("\n")
	for _, kid := range n.kids {
		writeNode(b, kid, depth+1)
	}
	b.WriteString(indent + "</" + n.name + ">\n")
}

func escapeXML(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// savePowerProfile writes the extracted file into the source tree. The path is
// fixed: it is the one the build compiles into res/xml/power_profile.xml.
func savePowerProfile(root, body string) (string, int, error) {
	if strings.TrimSpace(body) == "" {
		return "", 0, errors.New("there is nothing to save — read the profile first")
	}
	if !strings.Contains(body, "<item") && !strings.Contains(body, "<array") {
		return "", 0, errors.New("that does not look like a power profile")
	}
	var probe struct {
		XMLName xml.Name
	}
	if err := xml.Unmarshal([]byte(body), &probe); err != nil {
		return "", 0, fmt.Errorf("the profile is not valid XML: %w", err)
	}
	if probe.XMLName.Local != "device" && probe.XMLName.Local != "power_profile" {
		return "", 0, fmt.Errorf("the root is <%s>, not a power profile", probe.XMLName.Local)
	}

	path := filepath.Join(root, "src", "framework", "res", "xml", "power_profile.xml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", 0, err
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return "", 0, err
	}
	return path, strings.Count(body, "<item") + strings.Count(body, "<array"), nil
}
