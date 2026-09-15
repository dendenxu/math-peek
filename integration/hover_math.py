"""Extract a complete visible formula around a terminal character offset.

Offsets use Python Unicode code points, not AX/NSString UTF-16 units. Returned
``start`` and exclusive ``end`` refer to the original input, even when ``text``
has a conservatively repaired command or comes from a projected tmux pane.

Visible terminal text is not the original source: an off-screen delimiter,
trimmed space, or ambiguous wrapped command cannot be recovered reliably. This
module keeps ordinary newlines/spaces, requires both delimiters, and only joins
an unknown command fragment when the joined spelling is a known TeX command.
It deliberately does not guess user macros or join a valid command to letters
on the following row (``\\sin\nx`` must not become ``\\sinx``).
"""

from __future__ import annotations

import re
import json
import sys
import unicodedata


_MAX_DISPLAY_CHARS = 16_384
_MAX_DISPLAY_LINES = 80
_MAX_INLINE_CHARS = 2_048
_MAX_INLINE_LINES = 12
_VERTICAL_BORDERS = frozenset(
    chr(value) for value in range(0x2500, 0x2580)
    if "VERTICAL" in unicodedata.name(chr(value), "")
    or "UP" in unicodedata.name(chr(value), "") and "DOWN" in unicodedata.name(chr(value), "")
)
_BOX_DRAWING = re.compile("[\u2500-\u257f]")
_FENCE_OPEN = re.compile(r"^((?: {0,3}>[ \t]?)* {0,3})(`{3,}|~{3,})[^\n]*(?:\n|$)")
_LETTERS = re.compile(r"[A-Za-z]+")
_ROW_ENVIRONMENTS = frozenset("matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix smallmatrix aligned alignedat align align* gather gathered cases array split".split())

# This is intentionally bounded: absence from the set means no reconstruction.
_KNOWN_COMMANDS = frozenset("""
frac dfrac tfrac sqrt sum prod coprod int iint iiint oint lim limits nolimits
infty partial nabla cdot times div pm mp le leq ge geq ne neq approx equiv sim
simeq cong propto in notin subset subseteq supset supseteq cup cap setminus
forall exists nexists neg land lor implies iff to mapsto rightarrow leftarrow
leftrightarrow Rightarrow Leftarrow Leftrightarrow longrightarrow longleftarrow
longleftrightarrow Longrightarrow Longleftarrow Longleftrightarrow uparrow
downarrow alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta
iota kappa lambda mu nu xi pi varpi rho varrho sigma varsigma tau upsilon phi
varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega
mathbb mathbf mathrm mathit mathcal mathscr mathsf mathtt boldsymbol operatorname
text textrm textbf textit begin end left right middle overline underline
overbrace underbrace hat widehat bar vec dot ddot dots ldots cdots vdots ddots
sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh log ln exp min max
arg det gcd Pr binom dbinom tbinom overset underset substack cases vphantom
hphantom phantom displaystyle textstyle scriptstyle scriptscriptstyle
big Big bigg Bigg bigl bigr Bigl Bigr biggl biggr Biggl Biggr langle rangle
lvert rvert lVert rVert vert Vert lceil rceil lfloor rfloor ell hbar emptyset
varnothing Re Im bmod pmod mod stackrel cancel bcancel xcancel boxed color
textcolor underbracket overbracket bracevert choose atop not accentset
""".split())


def _escaped(text: str, index: int) -> bool:
    count = 0
    index -= 1
    while index >= 0 and text[index] == "\\":
        count += 1
        index -= 1
    return count % 2 == 1


def _across_wrap(text: str, index: int, step: int, pane_padding: bool = False) -> str:
    """Ignore row breaks and confirmed pane right-padding next to delimiters."""
    if pane_padding and step == 1:
        padding = re.match(r" +(?=\r?\n)", text[index:])
        if padding:
            index += padding.end()
    while 0 <= index < len(text) and text[index] in "\r\n":
        index += step
        if pane_padding and step == -1:
            while index >= 0 and text[index] == " ":
                index -= 1
    return text[index] if 0 <= index < len(text) else ""


def _repair_commands(text: str, pane_padding: bool = False, continuation_indent: bool = False) -> str:
    output: list[str] = []
    previous = 0
    for slash in re.finditer(r"\\(?=[A-Za-z])", text):
        start = slash.start()
        if start < previous or _escaped(text, start):
            continue
        first = _LETTERS.match(text, start + 1)
        assert first is not None
        command = first.group()
        if command in _KNOWN_COMMANDS:
            continue
        end = first.end()
        for _ in range(3):
            # tmux's AX rows include cell padding up to the pane border. Only
            # disregard it for a known command repair inside a reliable pane.
            linebreak = re.match((r" *\r?\n" if pane_padding or continuation_indent else r"\r?\n") + (r"[ \t]*" if continuation_indent else ""), text[end:])
            if not linebreak:
                break
            fragment = _LETTERS.match(text, end + linebreak.end())
            if not fragment:
                break
            command += fragment.group()
            end = fragment.end()
            if command in _KNOWN_COMMANDS:
                output.append(text[previous:start])
                output.append("\\" + command)
                previous = end
                break
            if not any(known.startswith(command) for known in _KNOWN_COMMANDS):
                break
    output.append(text[previous:])
    return "".join(output)


def _repair_environment_rows(text: str) -> str:
    active: list[str] = []
    output: list[str] = []
    depth = 0
    for row in text.splitlines(keepends=True):
        depths: list[int] = []
        for index, char in enumerate(row):
            depths.append(depth)
            if not _escaped(row, index):
                depth += 1 if char == "{" else -1 if char == "}" else 0
        for marker in re.finditer(r"\\(begin|end)\{([^{}]+)\}", row):
            if _escaped(row, marker.start()):
                continue
            if marker.group(1) == "begin":
                active.append(marker.group(2))
            elif active and active[-1] == marker.group(2):
                active.pop()
        if any(environment in _ROW_ENVIRONMENTS for environment in active):
            spacing = re.search(r"\\\[([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:pt|em|ex|mm|cm|in|mu))\]\s*$", row)
            if spacing and depths[spacing.start()] == 0 and not _escaped(row, spacing.start()):
                row = row[:spacing.start()] + "\\" + row[spacing.start():]
            else:
                ending = re.search(r"\\([ \t]*)(\r?\n)?$", row)
                matrix = any(environment.endswith("matrix") for environment in active)
                if ending and depths[ending.start()] == 0 and not _escaped(row, ending.start()) and (matrix or any(not _escaped(row, match.start()) for match in re.finditer("&", row))):
                    row = row[:ending.start()] + "\\" + row[ending.start():]
        output.append(row)
    return "".join(output)


def _bare_source(candidate: str) -> bool:
    if not candidate.strip() or len(candidate) > _MAX_INLINE_CHARS or any(char in candidate for char in "`$\"';@#") or _BOX_DRAWING.search(candidate):
        return False
    depth = 0
    for index, char in enumerate(candidate):
        if _escaped(candidate, index):
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        elif char == "|" and depth <= 0:
            return False
    reduced = re.sub(r"\\(?:text|textrm|mathrm|operatorname|mathbb|mathbf|mathit|mathcal|mathsf|mathtt)\{[^{}]*\}", "x", candidate)
    reduced = re.sub(r"\\[A-Za-z]+", "x", reduced)
    if re.search(r"[A-Za-z]{3,}|[^\x00-\x7f]", reduced):
        return False
    if re.search(r"\b(?:if|for|in|let|var|fn|def|return|echo|print|const)\b", reduced) or not re.fullmatch(r"[A-Za-z0-9\s\\{}()\[\]=+*/^_.,:!<>?&%|-]+", reduced):
        return False
    return True


def _bare_join(left: str, right: str) -> bool:
    if not _bare_source(left) or not _bare_source(right):
        return False
    balance = sum((1 if char == "{" else -1) for i, char in enumerate(left) if char in "{}" and not _escaped(left, i))
    if balance > 0 or re.search(r"[=+*/^_({\[,<>-]\s*$", left) or re.match(r"\s*[=+*/^_)}\],<>-]", right):
        return True
    command = re.search(r"\\([A-Za-z]+)[ \t\r]*$", left)
    rest = re.match(r"[ \t]*([A-Za-z]+)", right)
    if command and command.group(1) in _KNOWN_COMMANDS and re.fullmatch(r"[ \t]*[A-Za-z][ \t\r]*", right):
        return True
    return bool(command and rest and command.group(1) not in _KNOWN_COMMANDS and command.group(1) + rest.group(1) in _KNOWN_COMMANDS)


def _bare_formula(text: str, offset: int) -> tuple[int, int] | None:
    if _inside_code(text, offset):
        return None
    start = text.rfind("\n", 0, offset) + 1
    end = text.find("\n", offset)
    if end == -1:
        end = len(text)
    for _ in range(3):
        previous = text.rfind("\n", 0, max(0, start - 1)) + 1
        if start > 0 and _bare_join(text[previous:start - 1], text[start:end]):
            start = previous
        else:
            break
    for _ in range(3):
        following = text.find("\n", end + 1)
        if following == -1:
            following = len(text)
        if end < len(text) and _bare_join(text[start:end], text[end + 1:following]):
            end = following
        else:
            break
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    candidate = _repair_commands(text[start:end], continuation_indent=True)
    if not start <= offset < end or not _bare_source(candidate):
        return None
    commands = re.findall(r"\\([A-Za-z]+)", candidate)
    balance = sum((1 if char == "{" else -1) for i, char in enumerate(candidate) if char in "{}" and not _escaped(candidate, i))
    if balance != 0 or not any(command in _KNOWN_COMMANDS for command in commands) or not re.search(r"[=+*/^_{}]", candidate):
        return None
    return start, end


def _inside_code(text: str, offset: int) -> bool:
    index = 0
    while index <= offset:
        if index == 0 or text[index - 1] == "\n":
            fence = _FENCE_OPEN.match(text[index:])
            if fence:
                end = _skip_fence(text, index, fence)
                if offset < end:
                    return True
                index = end
                continue
        if text[index] == "`" and not _escaped(text, index):
            end = _skip_code_span(text, index)
            if end is not None:
                if offset < end:
                    return True
                index = end
                continue
        index += 1
    return False


def project_visible_pane(text: str, offset: int) -> dict | None:
    """Crop a clearly repeated vertical pane layout, retaining original indices.

    At least three consecutive rows must have the same hovered-pane boundaries.
    Borders outside that pane may vary (for example, log decorations next door).
    CJK/full-width characters and ordinary wide emoji occupy two cells; combining
    marks occupy none. Complex emoji sequences and tabs cannot be mapped reliably
    without terminal font/settings information, so those layouts are rejected.
    ``positions[i]`` maps each projected character back to the original input.
    """
    rows = text.splitlines(keepends=True)
    starts: list[int] = []
    cursor_row = None
    position = 0
    for index, row in enumerate(rows):
        starts.append(position)
        if position <= offset < position + len(row):
            cursor_row = index
        position += len(row)
    if cursor_row is None:
        return None
    layout_cache: dict[int, dict[int, int] | None] = {}

    def layout(row_index: int) -> dict[int, int] | None:
        if row_index in layout_cache:
            return layout_cache[row_index]
        column = 0
        borders_by_column: dict[int, int] = {}
        for index, char in enumerate(rows[row_index].rstrip("\r\n")):
            codepoint = ord(char)
            if char in "\t\u200c\u200d\ufe0e\ufe0f" or 0x1F3FB <= codepoint <= 0x1F3FF or 0x1F1E6 <= codepoint <= 0x1F1FF:
                layout_cache[row_index] = None
                return None
            if char in _VERTICAL_BORDERS:
                borders_by_column[column] = index
            if unicodedata.combining(char) or unicodedata.category(char) in ("Mn", "Me", "Cf"):
                continue
            column += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        layout_cache[row_index] = borders_by_column
        return borders_by_column

    current = rows[cursor_row].rstrip("\r\n")
    cursor_col = offset - starts[cursor_row]
    current_layout = layout(cursor_row)
    if not current_layout or cursor_col in current_layout.values() or cursor_col >= len(current):
        return None
    left = max((column for column, index in current_layout.items() if index < cursor_col), default=None)
    right = min((column for column, index in current_layout.items() if index > cursor_col), default=None)

    def same_layout(row_index: int) -> bool:
        candidate = layout(row_index)
        if candidate is None or left is not None and left not in candidate or right is not None and right not in candidate:
            return False
        # A neighboring pane's decorations do not change this pane's boundary.
        # New borders inside it do change the layout, so stop projection there.
        return not any((left is None or column > left) and (right is None or column < right) for column in candidate)

    first = last = cursor_row
    while first > 0 and same_layout(first - 1):
        first -= 1
    while last + 1 < len(rows) and same_layout(last + 1):
        last += 1
    if last - first + 1 < 3:
        return None
    chunks: list[str] = []
    positions: list[int] = []
    projected_offset = None
    for row_index in range(first, last + 1):
        row = rows[row_index].rstrip("\r\n")
        row_layout = layout(row_index)
        assert row_layout is not None
        begin = 0 if left is None else row_layout[left] + 1
        stop = len(row) if right is None else row_layout[right]
        if row_index == cursor_row:
            projected_offset = len(positions) + cursor_col - begin
        chunks.append(row[begin:stop])
        positions.extend(range(starts[row_index] + begin, starts[row_index] + stop))
        if row_index < last:
            chunks.append("\n")
            positions.append(starts[row_index] + len(rows[row_index]) - 1)
    return {"text": "".join(chunks), "offset": projected_offset, "positions": positions}


def _skip_fence(text: str, start: int, fence: re.Match) -> int:
    marker = fence.group(2)
    close = re.compile(r"^(?: {0,3}>[ \t]?)* {0,3}" + re.escape(marker[0]) + "{" + str(len(marker)) + r",}[ \t]*(?:\r?\n|$)")
    end = start + fence.end()
    while end < len(text):
        newline = text.find("\n", end)
        line_end = len(text) if newline == -1 else newline + 1
        if close.match(text[end:line_end]):
            return line_end
        end = line_end
    return len(text)


def _skip_code_span(text: str, start: int) -> int | None:
    run = re.match(r"`+", text[start:])
    assert run is not None
    marker = run.group()
    end = text.find(marker, start + len(marker))
    while end != -1:
        if (end == 0 or text[end - 1] != "`") and (end + len(marker) == len(text) or text[end + len(marker)] != "`"):
            return end + len(marker)
        end = text.find(marker, end + len(marker))
    return None


def _closing(text: str, opening: str, closing: str, start: int, pane_padding: bool = False) -> int | None:
    inline = opening in ("$", "\\(")
    max_chars = _MAX_INLINE_CHARS if inline else _MAX_DISPLAY_CHARS
    max_lines = _MAX_INLINE_LINES if inline else _MAX_DISPLAY_LINES
    limit = min(len(text), start + len(opening) + max_chars + len(closing))
    position = start + len(opening)
    while True:
        end = text.find(closing, position, limit)
        if end == -1:
            return None
        if _escaped(text, end):
            position = end + len(closing)
            continue
        if opening == "$":
            before = _across_wrap(text, end - 1, -1, pane_padding)
            after = text[end + 1] if end + 1 < len(text) else ""
            # Do not skip a rejected nearest dollar: that would consume prices
            # and unrelated later formulas as one expression.
            if not before or before.isspace() or before == "$" or after == "$" or after.isdigit():
                return None
        body = text[start + len(opening):end]
        if not body.strip() or body.count("\n") >= max_lines or _BOX_DRAWING.search(body) or "`" in body:
            return None
        return end


def _extract(text: str, offset: int, pane_padding: bool = False) -> tuple[int, int] | None:
    i = 0
    while i < len(text) and i <= offset:
        if i == 0 or text[i - 1] == "\n":
            fence = _FENCE_OPEN.match(text[i:])
            if fence:
                i = _skip_fence(text, i, fence)
                continue
        if text[i] == "`" and not _escaped(text, i):
            code_end = _skip_code_span(text, i)
            if code_end is not None:
                i = code_end
                continue
        opening = closing = ""
        if not _escaped(text, i):
            if text.startswith("$$", i):
                opening = closing = "$$"
            elif text.startswith("\\[", i):
                opening, closing = "\\[", "\\]"
            elif text.startswith("\\(", i):
                opening, closing = "\\(", "\\)"
            elif text[i] == "$":
                before = text[i - 1] if i else ""
                after = _across_wrap(text, i + 1, 1, pane_padding)
                if after and not after.isspace() and before != "$" and not (before.isascii() and (before.isalnum() or before == "_")):
                    opening = closing = "$"
        if opening:
            end = _closing(text, opening, closing, i, pane_padding)
            if end is not None:
                end += len(closing)
                if i <= offset < end:
                    return i, end
                i = end
                continue
            i += len(opening)
            continue
        i += 1
    return None


def extract_hover_formula(text: str, offset: int) -> dict | None:
    """Return ``{text, start, end}`` for the formula under ``offset``, or None.

    No nearest-formula selection is performed: ordinary text, code, borders,
    partial formulas, and out-of-range offsets do not trigger a popup. A tmux
    projection can make ``start:end`` a bounding range rather than a contiguous
    copy of ``text``; do not use that range to replace terminal contents.
    """
    if not isinstance(text, str) or not isinstance(offset, int) or not 0 <= offset < len(text):
        return None
    projection = project_visible_pane(text, offset)
    source = projection["text"] if projection else text
    cursor = projection["offset"] if projection else offset
    match = _extract(source, cursor, pane_padding=bool(projection))
    bare = match is None
    if bare:
        match = _bare_formula(source, cursor)
    if match is None:
        return None
    start, end = match
    formula = _repair_environment_rows(_repair_commands(source[start:end], pane_padding=bool(projection), continuation_indent=bare))
    if projection:
        start, end = projection["positions"][start], projection["positions"][end - 1] + 1
    return {"text": formula, "start": start, "end": end}


def _main() -> int:
    """One JSON request on stdin, one nullable JSON result on stdout."""
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        result = extract_hover_formula(request.get("text"), request.get("offset"))
    except (ValueError, TypeError) as error:
        print("null")
        print("hover_math: " + str(error), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
