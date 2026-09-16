<p align="center"><img src="assets/icon.png" width="112" alt="Math Peek icon"></p>

# Math Peek

**Hover over LaTeX in your terminal and read the formula.**

A standalone macOS menu-bar app. No selection, copying, remote installation, or
terminal plugin is required. Installation, the CLI, text capture, and hover
rendering are native: **no Python runtime**.

[中文](README.md) · [Download](https://github.com/dendenxu/math-peek/releases/latest)

![Actual Math Peek hover: inline, boxed and multiline formulas, then move away to dismiss](screenshots/hover-demo.gif)

## Install

### Homebrew

```sh
brew install --cask dendenxu/tap/math-peek
open -a "Math Peek"
```

Installs the precompiled app and `math-peek` CLI. No Swift compiler or Python is
needed. If a recent Homebrew version reports an untrusted tap, run
`brew trust --cask dendenxu/tap/math-peek`, then retry installation.
Quit Math Peek before updating with `brew upgrade --cask dendenxu/tap/math-peek`.

### Download

Get `Math.Peek-1.1.1-universal.zip` from [Releases](https://github.com/dendenxu/math-peek/releases/latest),
extract it, and move `Math Peek.app` to Applications. The universal app supports
Apple Silicon and Intel Macs. Requires macOS 13+.

The current release is ad-hoc signed and **not Apple-notarized**. If macOS blocks
first launch, review the app in System Settings > Privacy & Security and choose
Open Anyway. A SHA256 checksum accompanies the archive.

### Build From Source

Requires Swift 5.9+. Recent Xcode Command Line Tools can build directly;
older toolchains need full Xcode to package app resources. The installer checks this prerequisite.
The first build downloads the pinned SwiftMath dependency.

```sh
git clone https://github.com/dendenxu/math-peek.git
cd math-peek
./install.sh
open "$HOME/Applications/Math Peek.app"
```

The default installer includes all native features and automatically discovers
installed terminals, including iTerm2. There is no `--skip-iterm`, separate
Python integration, or iTerm2 Python API setup. The source installer places the
app in `~/Applications` and the command in `~/.local/bin`.

## First Use

1. Open Math Peek and grant Accessibility in its setup window.
2. Enable hover. Setup lists the currently enabled terminals.
3. Bring your terminal to the foreground and move the pointer over formula text.
4. Move away to dismiss. Launch at Login is optional.

Try these exact examples:

```sh
printf '%s\n' '$e^{i\pi}+1=0$' '$$\boxed{K = \frac{P}{P+R}}$$'
```

The app stays in the `M∑` menu bar; the reader does not need to remain open.

## Adding A Terminal

Use Add Terminal in setup, or **Terminal Apps > Add Application...**. Choose the
`.app`, then switch back to that terminal and hover over a formula.
**It takes effect immediately: no refresh or restart.** Custom apps can use the same flow.

Unchecking stops hover immediately. Removed apps stay removed during discovery.
Automatically Find Terminals controls discovery; Find Installed Terminals Now
runs a manual scan. Being listed means the app is enabled, not that every text
interface or application version has been verified compatible.

## Compatibility And Permissions

- **iTerm2 / Terminal.app:** native Accessibility text and character positions.
- **Ghostty:** accessible source text, but the current version lacks character position APIs required for hover.
- **cmux:** automatically discovered; the current version's incomplete text and position APIs limit hover support.
- **WezTerm, Alacritty, kitty, Warp, Hyper:** automatically discovered; hover depends on their Accessibility text and position APIs.
- **Custom apps:** add the `.app`; it must expose accessible text and character positions.

Math Peek reads original text and native character positions. It does not use OCR
or require Screen Recording permission. Discovery is not a blanket compatibility
guarantee for every app, version, or feature. Missing position APIs produce a clear
status; clipboard and file preview remain available.
See [native terminal API requirements](docs/terminal-compatibility.md) for custom apps and verified limitations.

## Reader And CLI

Hover recognizes `$...$`, `$$...$$`, `\(...\)`, `\[...\]`, and clear standalone
raw TeX with known commands. Multiline `aligned`, common matrices, and complete
outer `\boxed{...}` formulas work. Unsupported syntax falls back to source text.
A complete bare `\boxed{...}` also works inside a sentence without dollar delimiters;
only the formula itself triggers hover. Code blocks, inline code, shell paths such
as `$HOME/Applications/...`, and ambiguous currency are handled conservatively.

The popup scales to fit without animations. Moving within the same formula does
not keep repositioning it. Open Reader supports longer Markdown with bundled KaTeX.

Control-Command-M reads the selected or visible text in an enabled terminal;
in other apps it previews the clipboard. Reader capture and follow require
accessible selection or visible text. Hover additionally needs character positions.
The app never selects all text or changes your clipboard to capture a terminal.

```sh
math-peek --clipboard
math-peek answer.md
cat answer.md | math-peek
math-peek --capture
math-peek --follow
```

Inputs are UTF-8, up to 2 MB. Homebrew installs the CLI automatically. For source
installation, add `~/.local/bin` to PATH. The old Python RPC `--serve` is removed.

## Troubleshooting

After adding an app, ensure it is checked, hover is enabled, and the terminal is
frontmost. No refresh is necessary. Follow the setup status for missing
Accessibility permission or missing terminal position APIs.

The current release uses an ad-hoc signature, so updating or rebuilding may invalidate
an earlier Accessibility grant. First try turning Math Peek's Accessibility switch
back on in System Settings. If the switch is on but Math Peek's setup still reports
missing permission, remove the old entry, use "+" to add the currently installed
`Math Peek.app`, and enable it. Check the permission status in Math Peek itself;
removing and re-adding is unnecessary when the switch restores access.

Use the two exact examples first. Incomplete delimiters, code blocks, and
inaccessible text do not force a popup. Clipboard and file preview remain available.
Diagnostics under `~/Library/Caches/Math Peek` contain status and timing, not
terminal text. Disk writes and login-status polling run off the main thread.

## Development

```sh
scripts/test_native.sh
node --test web/core.test.cjs
./scripts/build_release.sh
```

VERSION controls release numbering. The release script generates a universal ZIP
and SHA256 checksum. A `v<version>` tag triggers GitHub Actions. Developer ID
signing and notarization require real DEVELOPER_ID_APPLICATION and NOTARY_PROFILE
credentials; otherwise the build is explicitly ad-hoc signed.

SwiftMath renders hover formulas. KaTeX, marked, and DOMPurify are bundled for the
reader. Third-party library and font licenses are included in the application.
