# iTerm2 adapter

Native hover extracts formulas in Swift and renders them with SwiftMath/AppKit;
it does not use this adapter, start Python, or create a WebKit view. Install that
path alone with `python3 install.py --skip-iterm`. The first build downloads the
SwiftMath revision pinned in `Package.swift` and requires Swift 5.9 or later;
the installer includes its math font bundle for offline rendering.

This optional Python adapter supplies the KaTeX reading window with iTerm2's
selected text, or its visible terminal viewport when nothing is selected. It does not run
commands in the terminal or require a remote SSH/tmux installation.

Install with `python3 install.py` (without `--skip-iterm`), then use the private
Python runtime. From the repository root:

```sh
"$HOME/Library/Application Support/Math Peek/runtime/bin/python3" integration/iterm_math_peek.py --capture
"$HOME/Library/Application Support/Math Peek/runtime/bin/python3" integration/iterm_math_peek.py --capture --screen
math-peek --serve
```

`--capture` emits one JSON object to stdout:

```json
{"text":"...","source":"iTerm2 selection","session_id":"..."}
```

On failure it emits `{"error":"..."}` and exits with status 1. Diagnostics go to
stderr. `--session ID` pins capture to a particular terminal session; `--screen`
ignores the selection, which is useful for a viewer that refreshes periodically.
The default capture timeout is 20 seconds. `--app PATH` changes the app launched
by the RPC and defaults to `~/Applications/Math Peek.app`.

## One shortcut

1. Start the adapter with `math-peek --serve`, or run the script with `--serve`
   using a Python interpreter that has `iterm2` installed.
2. In iTerm2, open Settings > Keys > Key Bindings and add a shortcut such as
   Command-Option-M.
3. Set the action to **Invoke Script Function** and the invocation to
   `math_peek()`.
4. Select a response or formula in iTerm2, then press the shortcut.

The app's global Control-Command-M shortcut already provides capture in iTerm2;
this RPC is an alternative for an iTerm2-specific binding.

For startup registration, put the script in
`~/Library/Application Support/iTerm2/Scripts/AutoLaunch/` and use the iTerm2
Python environment with the `iterm2` package installed. Alternatively, launch
the script with the installed private runtime when needed. A `.py` file in
iTerm2's Scripts directory also appears in the Scripts menu. Running the script
twice registers a duplicate RPC; stop the previous instance first.

iTerm2's Python API must be enabled. iTerm2 or macOS may display a first-use
authorization dialog when an external Python process connects. This adapter
does not change preferences or approve dialogs. The standalone viewer's paste
workflow remains available without this integration.

## Capture limits

The adapter rejoins rows only when iTerm2 marks them as soft wraps. Application
inserted newlines are preserved. Ordinary SSH output retains this information;
an SSH connection itself does not prevent capture. A full-screen application or
ordinary tmux can repaint panes and turn original wrap information into screen
rows. The adapter cannot recover source text that never reached iTerm2, hidden
tmux scrollback, or the semantic boundary between adjacent tmux panes. Select a
single pane/response, copy from the application's own transcript, or export a
tmux pane using `tmux capture-pane -p -J -S -` when those distinctions matter.

Native hover has separate, conservative pane-aware extraction. It recognizes
delimited math and standalone raw TeX with known math commands, can rejoin split
commands, and handles neighboring pane decorations and split junctions when the
hovered pane's boundaries remain stable. It also repairs narrowly recognizable
damaged row separators in matrix/aligned-style environments. It does not infer
missing mathematical symbols, and those repairs do not turn viewport capture
into an exact reconstruction of the original output.

Visible-screen capture reads the current viewport, including when iTerm2 is
scrolled into local history. A formula cut off above or below that viewport
still needs a larger selection. This adapter deliberately does not perform
automatic whole-terminal monitoring; the native viewer controls explicit
refresh/follow behavior.

## Official references

- [Session API: selections, contents, line info](https://iterm2.com/python-api/session.html)
- [LineContents.hard_eol and screen streaming](https://iterm2.com/python-api/screen.html)
- [RPC registration and shortcut invocation](https://iterm2.com/python-api/tutorial/rpcs.html)
- [Scripts menu, command-line execution, AutoLaunch](https://iterm2.com/python-api/tutorial/running.html)

AppleScript's `contents` property inserts a newline for every screen row and
does not expose soft-wrap metadata, so the Python API is preferred for formulas:
[AppleScript reference](https://iterm2.com/documentation-scripting.html).
