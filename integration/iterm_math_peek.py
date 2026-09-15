#!/usr/bin/env python3
"""Read iTerm2 text locally for Math Peek, or provide math_peek() as an RPC."""

import argparse
import asyncio
import contextlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile


class CaptureError(Exception):
    pass


def join_lines(lines):
    """Keep real newlines while rejoining iTerm2's soft-wrapped rows."""
    return "".join(line.string + ("\n" if line.hard_eol else "") for line in lines)


async def capture(iterm2, connection, session_id=None, screen_only=False):
    app = await iterm2.async_get_app(connection)
    if session_id:
        session = app.get_session_by_id(session_id)
    else:
        window = getattr(app, "current_window", None)
        if window is None:
            window = getattr(app, "current_terminal_window", None)
        tab = window.current_tab if window else None
        session = tab.current_session if tab else None
    if session is None:
        raise CaptureError("No active iTerm2 terminal session is available.")

    async with iterm2.Transaction(connection):
        if not screen_only:
            selection = await session.async_get_selection()
            text = await session.async_get_selection_text(selection)
            if text.strip():
                return {
                    "text": text,
                    "source": "iTerm2 selection",
                    "session_id": session.session_id,
                }

        # The mutable screen API ignores user scroll position. Read the viewport
        # explicitly so selecting a past response in scrollback also works.
        info = await session.async_get_line_info()
        # first_visible is relative to the retained buffer, while contents
        # coordinates include the lines already lost to scrollback overflow.
        first = info.overflow + max(0, info.first_visible_line_number)
        lines = await session.async_get_contents(first, session.grid_size.height)
        text = join_lines(lines)
    if not text.strip():
        raise CaptureError("The current iTerm2 viewport is empty.")
    return {
        "text": text,
        "source": "iTerm2 visible screen",
        "session_id": session.session_id,
    }


def create_request(text):
    directory = Path.home() / "Library/Caches/Math Peek/Requests"
    if directory.is_symlink():
        raise CaptureError("The Math Peek request directory must not be a symlink.")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    fd, filename = tempfile.mkstemp(prefix="math-peek-", suffix=".md", dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
    return Path(filename)


async def open_preview(text, app_path):
    if not app_path.is_dir():
        raise CaptureError("Math Peek.app is not installed at " + str(app_path))
    request = create_request(text)
    try:
        process = await asyncio.create_subprocess_exec(
            "/usr/bin/open", "-a", str(app_path), str(request),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, error = await process.communicate()
        if process.returncode:
            raise CaptureError(error.decode("utf-8", errors="replace").strip())
    except BaseException:
        request.unlink(missing_ok=True)
        raise
    # Launch Services returns before the app reads the file. The app removes it
    # after reading, so the sender must leave successful requests in place.


def arguments(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=(
            "Default: --serve. Register math_peek() and bind it in iTerm2 "
            "Settings > Keys > Key Bindings > Invoke Script Function. "
            "Only the local Mac needs this script and the iterm2 Python package."
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--capture", action="store_true", help="print one JSON capture and exit")
    mode.add_argument("--serve", action="store_true", help="register math_peek() until disconnected")
    parser.add_argument("--screen", "--no-selection", action="store_true",
                        help="capture the visible screen even if text is selected")
    parser.add_argument("--session", help="capture a specific iTerm2 session ID")
    parser.add_argument("--app", type=Path, default=Path.home() / "Applications/Math Peek.app",
                        help="path to Math Peek.app (used by the RPC)")
    parser.add_argument("--timeout", type=int, default=20,
                        help="capture timeout in seconds, including connection (default: 20)")
    args = parser.parse_args(argv)
    if args.timeout < 1:
        parser.error("--timeout must be at least 1")
    return args


def main(argv=None):
    args = arguments(argv)
    result = None
    error = None
    previous_alarm = None
    try:
        # Keep --help and clear missing-dependency errors usable without iterm2.
        import iterm2

        async def once(connection):
            nonlocal result
            result = await capture(iterm2, connection, args.session, args.screen)

        async def serve(connection):
            @iterm2.RPC
            async def math_peek(session_id=iterm2.Reference("id?")):
                captured = await capture(iterm2, connection, session_id)
                await open_preview(captured["text"], args.app.expanduser())

            await math_peek.async_register(connection)
            print("Math Peek ready: bind Invoke Script Function to math_peek().", file=sys.stderr)

        def timed_out(signum, frame):
            raise CaptureError(
                "iTerm2 capture timed out. Check iTerm2's Python API permission "
                "dialog and Settings > General > Magic > Enable Python API."
            )

        # The third-party library may print diagnostics to stdout. Reserve
        # stdout for a single JSON object when called from the native app.
        with contextlib.redirect_stdout(sys.stderr):
            if args.capture:
                previous_alarm = signal.signal(signal.SIGALRM, timed_out)
                signal.alarm(args.timeout)
                iterm2.run_until_complete(once, retry=False)
            else:
                iterm2.run_forever(serve, retry=False)
    except ImportError as exc:
        error = "Missing iTerm2 Python dependency: " + str(exc) + ". Install iterm2 in this interpreter."
    except KeyboardInterrupt:
        error = "Capture cancelled."
    except (Exception, SystemExit) as exc:
        error = str(exc) or type(exc).__name__
    finally:
        if previous_alarm is not None:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous_alarm)

    if args.capture:
        if error is None and result is None:
            error = "iTerm2 returned no capture. Check its Python API permission dialog."
        print(json.dumps({"error": error} if error else result, ensure_ascii=False))
    elif error:
        print("Math Peek: " + error, file=sys.stderr)
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
