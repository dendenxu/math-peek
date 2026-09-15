import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


MODULE = Path(__file__).resolve().parents[1] / "integration" / "hover_math.py"
SPEC = importlib.util.spec_from_file_location("hover_math", MODULE)
hover_math = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hover_math)
extract = hover_math.extract_hover_formula


class HoverMathTests(unittest.TestCase):
    def test_cli_accepts_one_json_request_and_returns_nullable_json(self):
        for text, offset, expected in (("前缀 $x$", 5, "$x$"), ("plain text", 1, None)):
            result = subprocess.run([sys.executable, str(MODULE)], input=json.dumps({"text": text, "offset": offset}), text=True, capture_output=True, check=True)
            response = json.loads(result.stdout)
            self.assertEqual(response["text"] if response else None, expected)

    def test_every_character_of_all_delimiter_forms_hits_complete_formula(self):
        for formula in ("$x^2$", "$$a+b$$", r"\[\frac{1}{2}\]", r"\(\alpha+1\)"):
            with self.subTest(formula=formula):
                text = "中文前缀 " + formula + " trailing"
                start = text.index(formula)
                for offset in range(start, start + len(formula)):
                    self.assertEqual(extract(text, offset), {"text": formula, "start": start, "end": start + len(formula)})
                self.assertIsNone(extract(text, start - 1))
                self.assertIsNone(extract(text, start + len(formula)))

    def test_repeated_formulas_use_hovered_occurrence(self):
        text = "$x$ then $x$ and $y$"
        self.assertEqual(extract(text, 10), {"text": "$x$", "start": 9, "end": 12})
        self.assertEqual(extract(text, 18)["text"], "$y$")
        self.assertIsNone(extract(text, 5))

    def test_inline_hard_wraps_preserve_whitespace(self):
        text = "answer $a +\nb + c$ done"
        expected = "$a +\nb + c$"
        self.assertEqual(extract(text, text.index("b"))["text"], expected)
        self.assertEqual(extract("$\nx\n$", 2)["text"], "$\nx\n$")

    def test_known_split_command_is_reconstructed_without_changing_offsets(self):
        text = "prefix $$\\fra\nc{a}{b} + \\alp\nha$$ suffix"
        result = extract(text, text.index("c{a}"))
        self.assertEqual(result["text"], r"$$\frac{a}{b} + \alpha$$")
        self.assertEqual(text[result["start"]:result["end"]], "$$\\fra\nc{a}{b} + \\alp\nha$$")

    def test_multiple_command_wraps_and_crlf(self):
        text = "$$\\oper\r\nator\r\nname{softmax}(x)$$"
        self.assertEqual(extract(text, 6)["text"], r"$$\operatorname{softmax}(x)$$")

    def test_valid_commands_unknown_macros_and_spaces_are_not_joined(self):
        for formula in ("$$\\sin\nx$$", "$$\\left\narrow$$", "$$\\custom\nmacro$$", "$$\\fra \nc{a}{b}$$", "$$\\fra\n c{a}{b}$$"):
            with self.subTest(formula=formula):
                self.assertEqual(extract(formula, 4)["text"], formula)

    def test_aligned_row_breaks_remain_intact(self):
        formula = "\\[\n\\begin{aligned}\na &= b \\\\\n c &= \\frac{1}{2}\n\\end{aligned}\n\\]"
        self.assertEqual(extract(formula, formula.index("c &"))["text"], formula)
        formula = "$$\\\\fra\nc$$"
        self.assertEqual(extract(formula, 4)["text"], formula)

    def test_code_spans_fences_quoted_fences_and_unclosed_fences_are_ignored(self):
        snippets = [
            "`$x$`", "`` a ` $x$ ``", "```latex\n$$x$$\n```", "~~~tex\n\\[x\\]\n~~~",
            "> ```\n> $x$\n> ```", "```\n$x$", "    ```\n$x$\n    ```",
        ]
        for text in snippets:
            with self.subTest(text=text):
                self.assertIsNone(extract(text, text.rindex("x")))
        self.assertEqual(extract("`$no$` then $yes$", 13)["text"], "$yes$")

    def test_currency_and_escaped_dollars_do_not_consume_later_math(self):
        text = r"Costs $5, $10 and $20.00. Range $5-$10. Literal \$x\$. Then $a+b$."
        for target in ("5,", "10 and", "20.00", "5-$", "x"):
            self.assertIsNone(extract(text, text.index(target)))
        self.assertEqual(extract(text, text.index("a+b"))["text"], "$a+b$")
        self.assertIsNone(extract("Price $5 today\nand $10 tomorrow", 8))

    def test_missing_delimiters_and_invalid_offsets_do_not_guess(self):
        for text in ("$$x", "$x", r"\[x", r"\(x", r"x\]", "x$"):
            self.assertIsNone(extract(text, min(1, len(text) - 1)))
        for offset in (-1, 3, 100):
            self.assertIsNone(extract("$x$", offset))
        self.assertIsNone(extract("", 0))

    def test_inline_line_and_size_limits(self):
        self.assertIsNone(extract("$" + "x\n" * 13 + "y$", 2))
        self.assertIsNone(extract("$" + "x" * 2050 + "$", 2))
        self.assertIsNotNone(extract("$$" + "x\n" * 20 + "y$$", 3))

    def test_unreliable_pane_borders_reject_cross_pane_formula(self):
        text = "$$x │ neighbor\ny$$ │ neighbor"
        self.assertIsNone(extract(text, 3))
        text = "$$x │ neighbor\ny$$  │ neighbor\nlast │ neighbor"
        self.assertIsNone(extract(text, 3))

    def test_repeated_tmux_borders_project_hovered_left_pane(self):
        rows = [r"$$ 1+\fra", "c{1}{2} +", " x$$     "]
        text = "\n".join(row + "│ other $bad$" for row in rows)
        result = extract(text, text.index("c{1}"))
        self.assertEqual(result["text"], "$$ 1+\\frac{1}{2} +\n x$$")
        self.assertEqual(result["start"], 0)
        self.assertEqual(result["end"], text.index(" x$$") + 4)
        self.assertNotIn("other", result["text"])

    def test_repeated_tmux_borders_project_hovered_right_pane(self):
        text = "left     │$$x+\nleft     │y+\nleft     │z$$"
        result = extract(text, text.index("y+"))
        self.assertEqual(result["text"], "$$x+\ny+\nz$$")
        self.assertEqual(result["start"], text.index("$$"))
        self.assertIsNone(extract(text, text.index("│")))

    def test_pane_projection_does_not_select_other_panes_formula(self):
        text = "blank    │$x$\nblank    │$x$\nblank    │$x$"
        self.assertIsNone(extract(text, text.index("blank")))
        self.assertEqual(extract(text, text.index("x"))["text"], "$x$")

    def test_chinese_and_emoji_neighbors_use_display_columns(self):
        text = "中文abcde│$$x+\n😀abcdefg│y+\n123456789│z$$"
        result = extract(text, text.index("y+"))
        self.assertEqual(result["text"], "$$x+\ny+\nz$$")
        self.assertEqual(result["start"], text.index("$$"))
        self.assertEqual(result["end"], len(text))
        self.assertIsNone(extract(text, text.index("😀")))

    def test_chinese_formula_pane_retains_source_indices_and_neighbor_isolation(self):
        text = "中文$$x+   │neighbor A\n   y+      │neighbor B\n  z$$      │neighbor C"
        result = extract(text, text.index("y+"))
        self.assertEqual(result["text"], "$$x+   \n   y+      \n  z$$")
        self.assertEqual(result["start"], text.index("$$"))
        self.assertEqual(result["end"], text.index("z$$") + 3)
        self.assertNotIn("neighbor", result["text"])

    def test_combining_marks_do_not_shift_pane_border(self):
        text = "e\u0301abc│$$x+\n1234│y+\n中文│z$$"
        self.assertEqual(extract(text, text.index("y+"))["text"], "$$x+\ny+\nz$$")

    def test_complex_emoji_layout_is_not_guessed_across_borders(self):
        text = "👩\u200d💻 │$$x+\n123 │y+\n123 │z$$"
        self.assertIsNone(hover_math.project_visible_pane(text, text.index("x+")))
        self.assertIsNone(extract(text, text.index("x+")))

    def test_emoji_offsets_are_codepoints_without_projection(self):
        text = "😀 中文 $\\alpha$"
        start = text.index("$")
        result = extract(text, text.index("alpha"))
        self.assertEqual(result, {"text": r"$\alpha$", "start": start, "end": len(text)})

    def test_realistic_padded_tmux_rows_repair_only_split_command(self):
        rows = [r"$$\fra", r"c{1}{2} + \text{hello ", r"world}$$"]
        text = "\n".join(row.ljust(90) + "│ neighboring pane" for row in rows)
        result = extract(text, text.index("c{1}"))
        self.assertEqual(result["text"], r"$$\frac{1}{2} + \text{hello " + " " * (90 - len(rows[1])) + "\nworld}$$")
        self.assertEqual(result["start"], 0)
        self.assertEqual(result["end"], text.index("world}$$") + len("world}$$"))
        self.assertNotIn("neighboring", result["text"])
        raw = "$$\\fra" + " " * 84 + "\nc{1}{2}$$"
        self.assertEqual(extract(raw, 4)["text"], raw)

    def test_single_dollar_delimiters_across_padded_tmux_wraps(self):
        for rows in (["$x", "$", "plain"], ["$", "x$", "plain"]):
            with self.subTest(rows=rows):
                text = "\n".join(row.ljust(90) + "│ neighbor" for row in rows)
                result = extract(text, text.index("x"))
                expected = rows[0].ljust(90) + "\n" + rows[1]
                self.assertEqual(result["text"], expected)
                self.assertIsNone(extract(expected, expected.index("x")))

    def test_padded_tmux_rows_preserve_valid_command_then_letter(self):
        rows = [r"$$\sin", "x$$", "plain"]
        text = "\n".join(row.ljust(90) + "│ neighbor" for row in rows)
        self.assertEqual(extract(text, text.index("x$$"))["text"], rows[0].ljust(90) + "\nx$$")

    def test_neighbor_log_borders_do_not_split_multiline_formula_pane(self):
        formula_rows = ["$$", r"v_{\mathrm{est}}", "", r"v_{\mathrm{pred}}", "+", r"K\left(v_{\mathrm{leg}}-v_{\mathrm{pred}}\right)", "$$"]
        logs = ["log", "  │ detail", "", "plain", "  │ more", "log", "  │ done"]
        rows = [log.ljust(24) + "│ " + formula for log, formula in zip(logs, formula_rows)]
        text = "\n".join(rows)
        expected = "$$\n " + "\n ".join(formula_rows[1:])
        offset = 0
        for row, formula_row in zip(rows, formula_rows):
            for column, character in enumerate(formula_row):
                if not character.isspace():
                    result = extract(text, offset + 26 + column)
                    self.assertIsNotNone(result)
                    self.assertEqual(result["text"], expected)
            offset += len(row) + 1

    def test_changing_borders_in_right_neighbor_do_not_break_left_formula(self):
        rows = ["$$x+", "y+", "z$$"]
        logs = ["plain", "  │ detail", "plain"]
        text = "\n".join(row.ljust(20) + "│" + log for row, log in zip(rows, logs))
        self.assertEqual(extract(text, text.index("y+"))["text"], rows[0].ljust(20) + "\n" + rows[1].ljust(20) + "\nz$$")

    def test_new_border_inside_hovered_pane_still_rejects_crossing(self):
        text = "left    │$$x+\nleft    │y │other\nleft    │z$$"
        self.assertIsNone(extract(text, text.index("x+")))

    def test_neighbor_horizontal_split_preserves_right_pane_formula_boundary(self):
        for junction in "┤├┼╢╟╫":
            with self.subTest(junction=junction):
                text = "plain".ljust(24) + "│$$\n" + "─" * 24 + junction + "x+y\n" + "  │ log".ljust(24) + "│$$"
                expected = "$$\nx+y\n$$"
                for offset in (text.index("$$"), text.index("x+y"), text.rindex("$$")):
                    self.assertEqual(extract(text, offset)["text"], expected)

    def test_formula_start_on_neighbor_split_row_does_not_shift_dollar_pairs(self):
        text = "─" * 24 + "┤$$\n" + "plain".ljust(24) + "│a+b\n" + "  │ log".ljust(24) + "│$$\n" + "plain".ljust(24) + "│text\n" + "plain".ljust(24) + "│$$c+d$$"
        self.assertEqual(extract(text, text.index("a+b"))["text"], "$$\na+b\n$$")
        self.assertEqual(extract(text, text.index("c+d"))["text"], "$$c+d$$")

    def test_standalone_raw_tex_formula_without_delimiters(self):
        formula = r"v_{\mathrm{pred}} = v_{\mathrm{prev}} + a_{\mathrm{world}}\Delta t"
        text = "plain\n  " + formula + "  \nplain"
        for index, character in enumerate(formula):
            if not character.isspace():
                self.assertEqual(extract(text, len("plain\n  ") + index)["text"], formula)
        self.assertEqual(extract(r"\frac{a}{b}", 4)["text"], r"\frac{a}{b}")

    def test_raw_tex_does_not_capture_shell_prose_or_code(self):
        for source in (r'print("\frac{a}{b}")', r"echo \frac{a}{b}", r"The formula is \frac{a}{b}", r"解释 \frac{a}{b}", r"/tmp/\alpha/file", r"const x = \frac{a}{b};", r"cost $5 then \alpha", r"x = custom_function(\alpha)"):
            with self.subTest(source=source):
                self.assertIsNone(extract(source, source.index("\\")))

    def test_raw_tex_in_pane_ignores_neighbor_code_and_preserves_offset(self):
        formula = r"v_{\mathrm{pred}} = a_{\mathrm{world}}\Delta t"
        text = "log".ljust(20) + "│plain\n" + " │ source".ljust(20) + "│" + formula + "\n" + "log".ljust(20) + "│plain"
        result = extract(text, text.index("Delta"))
        self.assertEqual(result["text"], formula)
        self.assertEqual(result["start"], text.index("v_{"))

    def test_matrix_single_backslash_and_aligned_spacing_rows_are_repaired(self):
        source = "$$\\begin{bmatrix}\na & b \\\nc & d\n\\end{bmatrix}$$"
        expected = "$$\\begin{bmatrix}\na & b \\\\\nc & d\n\\end{bmatrix}$$"
        self.assertEqual(extract(source, source.index("a &"))["text"], expected)
        source = "$$\\begin{aligned}\na &= b\n\\[8pt]\nc &= d\n\\end{aligned}$$"
        self.assertEqual(extract(source, source.index("a &"))["text"], source.replace("\\[8pt]", "\\\\[8pt]"))

    def test_environment_repairs_do_not_touch_unrelated_math_or_valid_rowbreaks(self):
        for source in ("$$a & b \\\nc & d$$", "$$\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}$$", "$$\\begin{aligned}\n\\[x+y]\n\\end{aligned}$$"):
            with self.subTest(source=source):
                self.assertEqual(extract(source, 3)["text"], source)

    def test_column_vector_single_row_backslash_is_repaired(self):
        source = "$$\\begin{bmatrix}\n\\hat p_{t|t-1}\\\n\\hat v_{t|t-1}\n\\end{bmatrix}$$"
        self.assertEqual(extract(source, source.index("p_{"))["text"], source.replace("p_{t|t-1}\\\n", "p_{t|t-1}\\\\\n"))

    def test_raw_formula_wraps_only_clear_math_continuations(self):
        for source, expected in (("x = \\fra\n  c{a}{b}", r"x = \frac{a}{b}"), ("v_{\\mathrm{pred}} =\n  a_{\\mathrm{world}}\\Delta t", "v_{\\mathrm{pred}} =\n  a_{\\mathrm{world}}\\Delta t"), ("x = \\frac{a+\n b}{c}", "x = \\frac{a+\n b}{c}")):
            with self.subTest(source=source):
                for offset, character in enumerate(source):
                    if not character.isspace():
                        self.assertEqual(extract(source, offset)["text"], expected)
        separate = "x = \\alpha\ny = \\beta"
        self.assertEqual(extract(separate, separate.index("beta"))["text"], r"y = \beta")
        self.assertIsNone(extract("x = \\frac{a\nordinary prose", 5))

    def test_aligned_spacing_after_expression_is_repaired_without_doubling_valid_breaks(self):
        damaged = "$$\\begin{aligned}\na &= b \\[8pt]\nc &= d\n\\end{aligned}$$"
        valid = damaged.replace("\\[8pt]", "\\\\[8pt]")
        self.assertEqual(extract(damaged, damaged.index("a &"))["text"], valid)
        self.assertEqual(extract(valid, valid.index("a &"))["text"], valid)
        outside = "$$a = b \\[8pt]$$"
        self.assertEqual(extract(outside, 3)["text"], outside)

    def test_raw_state_index_allows_grouped_bar_but_not_shell_pipeline(self):
        formula = r"\hat p_{t|t-1} = \hat v_{t|t-1} + \Delta t"
        self.assertEqual(extract(formula, formula.index("p_"))["text"], formula)
        self.assertIsNone(extract(r"\hat p = x | cat", 2))
        self.assertIsNone(extract(r"\alpha | \beta", 2))

    def test_bare_fallback_does_not_escape_fenced_code(self):
        for source in ("```latex\n\\frac{a}{b}\n```", "~~~\nx = \\alpha\n~~~", "```\nx = \\alpha"):
            with self.subTest(source=source):
                self.assertIsNone(extract(source, source.index("\\")))

    def test_raw_velocity_command_with_single_variable_on_wrapped_tail(self):
        formula = r"v_{\mathrm{pred}} = v_{\mathrm{prev}} + a_{\mathrm{world}}\Delta t"
        first, tail = formula.rsplit(" ", 1)
        rows = ["neighbor".ljust(20) + "│" + first + " ", "  │ log".ljust(20) + "│" + tail, "neighbor".ljust(20) + "│plain"]
        text = "\n".join(rows)
        expected = first + " \n" + tail
        for row_index in range(2):
            row_start = sum(len(row) + 1 for row in rows[:row_index])
            for column, character in enumerate(rows[row_index][21:]):
                if not character.isspace():
                    self.assertEqual(extract(text, row_start + 21 + column)["text"], expected)
        separate = r"x = \Delta" + "\ny = \\beta"
        self.assertEqual(extract(separate, separate.index("beta"))["text"], r"y = \beta")
        delimited = "$$\\sin\nx$$"
        self.assertEqual(extract(delimited, 4)["text"], delimited)

    def test_environment_row_repairs_preserve_nested_text_and_grouped_spacing(self):
        for source in ("$$\\begin{bmatrix}\n\\text{a\\\nb}\n\\end{bmatrix}$$", "$$\\begin{aligned}\n{a &= b \\[8pt]\nc}\n\\end{aligned}$$"):
            with self.subTest(source=source):
                self.assertEqual(extract(source, source.index("a"))["text"], source)
        escaped_brace = "$$\\begin{bmatrix}\n\\{a\\\nb\n\\end{bmatrix}$$"
        self.assertEqual(extract(escaped_brace, escaped_brace.index("a\\"))["text"], escaped_brace.replace("a\\\n", "a\\\\\n"))


if __name__ == "__main__":
    unittest.main()
