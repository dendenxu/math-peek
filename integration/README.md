# Native terminal capture

Math Peek now reads terminal selections and visible text directly through macOS
Accessibility in Swift. Installation, hover, the reading window, follow mode,
and the command-line launcher require no Python runtime or iTerm2 Python API.

Install the complete app with `./install.sh`, or use a prebuilt app from
[GitHub Releases](https://github.com/dendenxu/math-peek/releases).
Installed terminal apps are discovered automatically. Add custom terminal apps
from **Terminal Apps > Add Application...**; additions take effect immediately.

## Reading terminal text

- Focus an enabled terminal and press **Control-Command-M**. Math Peek reads its
  selection first, or its visible text if nothing is selected.
- `math-peek --capture` performs the same native capture.
- `math-peek --follow` refreshes that terminal's visible text every two seconds.
- `math-peek --clipboard`, a text file, or piped UTF-8 text opens the reader
  without requiring a terminal text interface.

Capture stays within the focused terminal pane and the visible text range.
It does not substitute the entire scrollback when a terminal cannot provide a
reliable visible range. Some terminal apps expose selected text but no full
viewport or mouse-to-character mapping. In that case, select and copy the
desired text, then use clipboard preview. Adding an app cannot supply interfaces
that the terminal itself does not implement.

SSH and tmux do not require any remote installation. Capture reads the text
presented by the local terminal; text outside the viewport and boundaries that
the terminal does not expose cannot be recovered automatically.

## Migrating an older installation

The previous `integration/iterm_math_peek.py` adapter, private Python runtime,
`math-peek --serve`, and `math_peek()` RPC are no longer used. Stop any older
adapter you started and remove its own iTerm2 AutoLaunch entry if you created
one. Replace an **Invoke Script Function: math_peek()** shortcut with the built-in
**Control-Command-M** shortcut. Existing terminal and Accessibility preferences
are retained by an app upgrade.

The old private runtime at
`~/Library/Application Support/Math Peek/runtime` is no longer required.
Installation leaves it alone so it does not remove files from an older setup.
