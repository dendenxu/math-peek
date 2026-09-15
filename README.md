<p align="center"><img src="assets/icon.png" width="112" alt="Math Peek icon"></p>

# Math Peek

Hover over LaTeX in iTerm2 and read the rendered formula in a small macOS popup.
No selection, remote installation, terminal image protocol, or Python process
is needed for hover. Math Peek reads local accessibility text, extracts formulas
in compiled Swift, and renders them with bundled KaTeX.

![A formula rendered in Math Peek's dark glass popup](screenshots/glass-preview.png)

The popup uses a monochrome glass background, follows the formula's size, and
does not take keyboard focus. There are no animations or intentional hover
delay. Mouse position is checked approximately every 16 ms; this is the polling
interval, not a guarantee of total rendering latency.

## Install

Requires macOS 13 or later, Python 3 for the installer, and Xcode Command Line
Tools (`xcode-select --install` if needed).

```sh
git clone https://github.com/dendenxu/math-peek.git
cd math-peek
python3 install.py --skip-iterm
open "$HOME/Applications/Math Peek.app"
```

This installs native hover and the clipboard/file reader. To also enable the
optional iTerm2 selection/screen capture, follow mode, and RPC integration, use
`python3 install.py` without `--skip-iterm`. Those features install Python
dependencies into a private environment under
`~/Library/Application Support/Math Peek/runtime`.

The app is installed in `~/Applications/Math Peek.app`. The Python command-line
launcher is linked at `~/.local/bin/math-peek`; keep the clone in place and add
`~/.local/bin` to your `PATH` if you want to use that command.

## First launch

The setup window walks through Accessibility permission, hover preview, and
launching at login. Allow **Math Peek** in **System Settings > Privacy & Security
> Accessibility**, choose whether to launch at login, then finish setup.

Math Peek runs in the menu bar without keeping a Dock icon or reading window
open. Use **Setup...** from the `M∑` menu to revisit setup, **Open Reader** when
needed, or **Launch at Login** to change startup behavior. Login startup uses
macOS `SMAppService`; macOS may ask you to approve
it in **System Settings > General > Login Items**.

![First-run setup with permission and login-start controls](screenshots/setup.png)

## Use

Bring iTerm2 to the foreground and move the pointer onto a formula. Move away to
dismiss the popup. Hover recognizes `$...$`, `$$...$$`, `\(...\)`, and `\[...\]`.
Matrices and `aligned` environments work within KaTeX's supported syntax. Code
spans and fenced code blocks are excluded; ambiguous currency is handled
conservatively.

| Control | Action |
| --- | --- |
| Menu bar `M∑ > Hover Formula Preview` | Enable or disable hover |
| Control-Command-M in iTerm2 | Open the selection, or visible screen, in the reader; requires optional capture integration |
| Control-Command-M in other apps | Preview the clipboard |
| Preview Clipboard | Open copied text from any app or terminal |
| Read Terminal / Follow Terminal | Capture once, or refresh the visible iTerm2 screen every two seconds |
| Pure LaTeX mode | Render a formula without delimiters in the reader |
| Services > Preview with Math Peek | Preview selected text in apps that support macOS text services |

The global shortcut works while Math Peek is running. It does not change shell
or iTerm2 key bindings. If another app owns the shortcut, use the menu bar or
reader buttons. Follow mode stops when the reading window closes or new
clipboard/file content is opened.

### 中文快速使用

首次启动按引导允许「辅助功能」、开启悬停，并选择是否登录时自动运行；完成后应用
留在菜单栏，不常驻 Dock 或阅读窗口。需要修改时点菜单栏 `M∑ → Setup...`。
让 iTerm2 处于前台，把鼠标移到带分隔符的公式上即可预览。不用框选，没有停留等待
或动画；悬停解析全部在 Swift 应用内完成，不启动 Python。SSH 和 tmux 不需要安装
任何东西。没有分隔符的裸 TeX 可以复制到阅读窗口，切换为「纯 LaTeX 公式」。

## Files, SSH, and tmux

Run these commands on the local Mac:

```sh
math-peek --clipboard
math-peek answer.md
cat answer.md | math-peek
math-peek --capture
math-peek --follow
```

The clipboard, file, and pipe workflows work with any terminal. Remote output
can be brought back over an ordinary SSH pipe:

```sh
ssh my-server 'cat /path/to/answer.md' | math-peek
ssh my-server 'tmux capture-pane -p -J -S - -t session:0.0' | math-peek
```

Hover currently targets iTerm2's accessibility interface. Native soft wraps are
rejoined by iTerm2. For tmux, Math Peek preserves math line breaks and repairs
split common commands such as `\fra` followed by `c` on the next row. Stable
vertical pane borders allow extraction from one pane, including ordinary CJK
and wide characters.

This is a preview overlay; it does not replace characters inside the terminal.
Missing delimiters, hidden tmux history, uncertain pane boundaries, and complex
emoji layouts cannot always be reconstructed. Exporting the target tmux pane
with `capture-pane -J` is useful for those cases. Very old scrollback may not be
exposed through iTerm2's accessibility interface. KaTeX supports mathematical
TeX, not arbitrary TeX documents; unsupported syntax remains visible as text.
Reader inputs are limited to 2 MB.

## Permissions and local data

Hover requires Math Peek's macOS Accessibility permission. It does not require
iTerm2's Python API. Optional capture/follow features use that API and may need
**iTerm2 Settings > General > Magic > Enable Python API**, plus first-use
authorization. Clipboard and file preview work independently of either API.

Rendering is offline: KaTeX, marked, DOMPurify, and fonts are bundled. Pasted
remote images are not loaded, and preview links do not navigate. Content is not
stored in browser storage. Pipe and RPC handoff files use a private local
directory, `~/Library/Caches/Math Peek/Requests/`, and are deleted after the app
reads them. Files left by an interrupted handoff can be removed manually.

Quit Math Peek before reinstalling. This source build is signed locally; a
rebuild can change its code signature and invalidate Accessibility permission.
If hover stops after an update, remove the old Math Peek entry from Accessibility
settings, add `~/Applications/Math Peek.app` again, and enable it.

The setup and reading windows display hover permission status. Local diagnostics
in `~/Library/Caches/Math Peek/hover-status.json` record stage, permission, process,
and timing information. `~/Library/Caches/Math Peek/app-status.json` records setup,
hover, and login-startup state. Neither diagnostic file includes terminal text.

## Development

The native extractor is `native/HoverMath.swift`. Hover uses that implementation
directly; `integration/hover_math.py` is a reference implementation for tests.
The optional iTerm2 adapter is documented in [integration/README.md](integration/README.md).

```sh
mkdir -p build
xcrun swiftc -O native/HoverMath.swift tests/native_math/main.swift -o build/native-math-tests
build/native-math-tests tests/native_math/fixtures.json
python3 -m unittest discover -s tests -v
node --test web/core.test.cjs
```

The native suite contains 109 parity fixtures. `tests/hover_demo.py` and
`tests/ax_probe/main.swift` provide an isolated iTerm2/tmux smoke test; the AX probe
requires Accessibility permission and looks for the explicit demo marker.
Do not use private terminal captures as repository fixtures.

Bundled dependency versions and their license files are in `web/vendor/`.
To uninstall, disable **Launch at Login** from the menu bar, quit the app, then remove
`~/Applications/Math Peek.app`, `~/Library/Application Support/Math Peek`, and
`~/.local/bin/math-peek`.
