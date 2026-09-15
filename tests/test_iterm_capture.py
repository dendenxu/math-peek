"""Checks for local capture behavior; no iTerm2 connection is opened."""

import importlib.util
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "integration/iterm_math_peek.py"
SPEC = importlib.util.spec_from_file_location("iterm_math_peek", SCRIPT)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def line(text, hard_eol):
    return SimpleNamespace(string=text, hard_eol=hard_eol)


class CaptureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.session = SimpleNamespace(
            session_id="test-session",
            grid_size=SimpleNamespace(height=3),
            async_get_selection=AsyncMock(return_value=object()),
            async_get_selection_text=AsyncMock(return_value=""),
            async_get_line_info=AsyncMock(return_value=SimpleNamespace(
                overflow=100, first_visible_line_number=25)),
            async_get_contents=AsyncMock(return_value=[line("visible math", True)]),
        )
        self.app = SimpleNamespace(
            current_window=SimpleNamespace(
                current_tab=SimpleNamespace(current_session=self.session)),
            get_session_by_id=Mock(return_value=self.session),
        )
        self.transaction = AsyncMock()
        self.api = SimpleNamespace(
            async_get_app=AsyncMock(return_value=self.app),
            Transaction=Mock(return_value=self.transaction),
        )

    async def test_selection_takes_priority_and_is_preserved(self):
        self.session.async_get_selection_text.return_value = "  $x^2$\n"
        result = await adapter.capture(self.api, None)
        self.assertEqual(result, {
            "text": "  $x^2$\n", "source": "iTerm2 selection", "session_id": "test-session",
        })
        self.session.async_get_line_info.assert_not_awaited()
        self.session.async_get_contents.assert_not_awaited()
        self.transaction.__aenter__.assert_awaited_once()
        self.transaction.__aexit__.assert_awaited_once()

    async def test_soft_wrap_is_joined_and_real_newlines_are_preserved(self):
        self.session.async_get_contents.return_value = [
            line(r"\frac{long", False),
            line("name}{2}", True),
            line("next paragraph", True),
        ]
        result = await adapter.capture(self.api, None)
        self.assertEqual(result["text"], "\\frac{longname}{2}\nnext paragraph\n")
        self.assertEqual(result["source"], "iTerm2 visible screen")

    async def test_screen_mode_does_not_read_selection(self):
        self.session.async_get_selection_text.return_value = "stale selection"
        result = await adapter.capture(self.api, None, screen_only=True)
        self.assertEqual(result["text"], "visible math\n")
        self.session.async_get_selection.assert_not_awaited()
        self.session.async_get_selection_text.assert_not_awaited()

    async def test_viewport_coordinates_include_overflow(self):
        await adapter.capture(self.api, None)
        self.session.async_get_contents.assert_awaited_once_with(125, 3)

    async def test_whitespace_selection_falls_back_to_viewport(self):
        self.session.async_get_selection_text.return_value = " \n\t"
        result = await adapter.capture(self.api, None)
        self.assertEqual(result["text"], "visible math\n")

    async def test_session_id_pins_capture(self):
        await adapter.capture(self.api, None, session_id="test-session")
        self.app.get_session_by_id.assert_called_once_with("test-session")

    async def test_missing_requested_session_raises(self):
        self.app.get_session_by_id.return_value = None
        with self.assertRaisesRegex(adapter.CaptureError, "No active iTerm2"):
            await adapter.capture(self.api, None, session_id="closed-session")

    async def test_missing_current_window_raises(self):
        self.app.current_window = None
        with self.assertRaisesRegex(adapter.CaptureError, "No active iTerm2"):
            await adapter.capture(self.api, None)

    async def test_empty_screen_raises(self):
        self.session.async_get_contents.return_value = [line("  ", True)]
        with self.assertRaisesRegex(adapter.CaptureError, "viewport is empty"):
            await adapter.capture(self.api, None)


class RequestTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="math-peek-adapter-test-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.home_patch = patch.object(adapter.Path, "home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.directory = self.home / "Library/Caches/Math Peek/Requests"
        self.app = self.home / "Math Peek.app"
        self.app.mkdir()

    def test_request_is_utf8_private_and_inside_owned_directory(self):
        content = "A formula: \\(x^2\\)\n"
        request = adapter.create_request(content)
        self.assertEqual(request.parent, self.directory)
        self.assertTrue(request.name.startswith("math-peek-"))
        self.assertEqual(request.suffix, ".md")
        self.assertEqual(request.read_text(encoding="utf-8"), content)
        self.assertEqual(stat.S_IMODE(request.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)

    def test_symlink_request_directory_is_rejected(self):
        target = self.home / "unrelated"
        target.mkdir()
        self.directory.parent.mkdir(parents=True)
        self.directory.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(adapter.CaptureError, "must not be a symlink"):
            adapter.create_request("math")
        self.assertEqual(list(target.iterdir()), [])

    async def test_failed_open_cleans_only_new_request(self):
        existing = adapter.create_request("another request")
        process = SimpleNamespace(
            returncode=1, communicate=AsyncMock(return_value=(b"", b"Launch failed")))
        with patch.object(adapter.asyncio, "create_subprocess_exec", AsyncMock(return_value=process)):
            with self.assertRaisesRegex(adapter.CaptureError, "Launch failed"):
                await adapter.open_preview("new math", self.app)
        self.assertEqual(list(self.directory.iterdir()), [existing])
        self.assertEqual(existing.read_text(), "another request")

    async def test_successful_open_leaves_request_for_asynchronous_app_read(self):
        process = SimpleNamespace(
            returncode=0, communicate=AsyncMock(return_value=(b"", b"")))
        launcher = AsyncMock(return_value=process)
        with patch.object(adapter.asyncio, "create_subprocess_exec", launcher):
            await adapter.open_preview("new math", self.app)
        requests = list(self.directory.iterdir())
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].read_text(), "new math")
        self.assertEqual(launcher.call_args.args[:3], ("/usr/bin/open", "-a", str(self.app)))
        self.assertEqual(launcher.call_args.args[3], str(requests[0]))


if __name__ == "__main__":
    unittest.main()
