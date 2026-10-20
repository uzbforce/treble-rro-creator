# Windows

The project runs natively on Windows. No WSL, no VM, no Cygwin.

`build.cmd` finds Git for Windows, runs `build.sh` with it, and returns the same
exit code. Everything the build produces (module zips, `service.sh`,
`customize.sh`) uses Linux line endings and POSIX paths, because it runs on an
Android phone — not on Windows.

---

## Which command do I run?

| Where you are | Command |
|---|---|
| **Explorer** | double-click `build.cmd` |
| **cmd.exe** | `build.cmd` |
| **PowerShell** (including VS Code) | `.\build.cmd` |
| **Git Bash** | `./build.sh` |
| **VS Code with “WSL: …” in the bottom-left** | not supported on a Windows drive — see below |

`build.cmd` accepts the same commands and options as `build.sh`:

```bat
build.cmd                  build
build.cmd setup            install / repair tools
build.cmd doctor           verify the toolchain
build.cmd check            validate config.env
build.cmd clean            remove build output
build.cmd clean --all      start over for another device
```

---

## First run

1. `build.cmd` checks `aapt2`, `zipalign`, `apksigner` and `framework-res.apk`.
2. Whatever is missing is downloaded into `tools/`:
   - Google build-tools for Windows (`build-tools_r36_windows.zip`) → about
     33 MB extracted; the 120 MB archive is deleted afterwards.
   - Android 13 platform resources (`platform-33_r02.zip`) → the resource
     dictionary `tools/framework-res.apk`.
3. The build starts immediately.

Roughly **20–30 seconds** on a normal connection. Nothing is installed
system-wide; deleting `tools/` removes the whole toolchain.

Requirements:

- **Git for Windows** — provides `bash.exe`, `curl`, `unzip`.
- **JDK 17+** — `apksigner` is a Java tool:
  `winget install EclipseAdoptium.Temurin.17.JDK`.
  Check with `java -version` in a fresh terminal after installing.

---

## Verify the toolchain

```bat
build.cmd doctor
```

It prints, for each tool:

- every copy it can find (PATH and `tools/`),
- what the file really is (Windows executable, Linux binary, shell script,
  archive),
- whether it **actually runs** (`aapt2 version`, `apksigner --version`),
- whether anything in `tools/` or on `PATH` belongs to another platform.

Exit code `0` means a build should work, so it is safe in scripts. A healthy run
ends with:

```
  ✓ Toolchain is correct for this platform — ./build.sh will work.
```

`build.cmd setup` is the repair path: it re-downloads the Windows toolchain and
removes Linux leftovers. `build.cmd` itself also repairs a missing toolchain on
the next run.

---

## WSL: why it is refused

WSL is a Linux machine with access to the same files. If you build this project
from WSL while it lives on `C:\`, two things go wrong:

1. Linux binaries (`aapt2`, `zipalign`) are downloaded into the **same**
   `tools/` folder the Windows build uses. Windows then reports them as found
   and fails later with `Exec format error`.
2. Output files and permissions are created by Linux for a build that Windows
   then tries to read.

For that reason `build.sh` stops with an explanation when it detects WSL and a
checkout under `/mnt/c/…` (or any other Windows drive). The fix is one of:

- **Use Windows:** open a cmd / PowerShell terminal (or just double-click
  `build.cmd`).
- **Use Linux properly:** clone the project inside the Linux filesystem, e.g.
  `~/treble-ro-creator`, and run `./build.sh` there.

### VS Code

VS Code picks a terminal per window:

- Bottom-left says **“WSL: kali-linux”** → you are inside WSL. Run `build.cmd`
  in a Windows terminal, or close the remote window and reopen the folder
  normally.
- Bottom-left says nothing / shows a folder → the integrated terminal is
  usually PowerShell. Run `.\build.cmd`.

If `.\build.cmd` opens `build.cmd` in an editor instead of running it, your
PowerShell profile may have a conflicting alias; use `cmd /c build.cmd`.

---

## Cleaning up

| Want to remove | Delete |
|---|---|
| Build output and APKs | `build.cmd clean` (or delete `build/` and `out/`) |
| The downloaded toolchain | delete `tools/` |
| Everything, start over | `build.cmd clean --all` |

`clean --all` copies `config.env`, the module scripts and `src/vendor/` into
`backups/` first, then puts `config.env` and `src/module/sepolicy.rule` back to
the version this clone shipped with — `git checkout` for a tracked file, and the
bundled copy in `templates/recoveries/` only when there is no `.git` (a zip
download). Either way the restored file is the current one, not a copy that
froze at some older commit, and your own version stays in `backups/`.

---

## Common Windows messages

| Message | Meaning / fix |
|---|---|
| `Git for Windows was not found` | Install Git for Windows, reopen the terminal. WSL's `bash.exe` is deliberately rejected. |
| `Java not found — apksigner needs a JDK (17+)` | Install Temurin 17 (winget line above), then retry. |
| `... is not a Windows program (no PE header)` | A Linux binary is shadowing the `.exe`. Run `build.cmd setup`, or delete the named file. |
| `cannot execute binary file` / `Exec format error` | Same cause: Linux toolchain in `tools/`. `build.cmd setup` replaces it. |
| `Access is denied` on `.cmd` files | Some antivirus products block batch files in Downloads. Move the project to a normal folder (e.g. `C:\dev\`) or allow the file. |
| Windows Defender slows the build down | Add the project folder to the exclusion list; `aapt2` starts many short-lived processes. |

If a path contains spaces, that is fine — both launchers quote paths. Avoid
running from a network share or an archive-mount (`\\?\`): file locking and
symlinks in Android tooling can fail there.

---

## Manual toolchain (optional)

If you prefer your own Android SDK, put `aapt2.exe`, `zipalign.exe` and
`apksigner` on `PATH` (or in `tools/`) and set `PLATFORM_JAR` in `config.env`
to your `framework-res.apk`. `build.cmd doctor` then reports what it will use.
