"""Manual fixture for an isolated iTerm2/tmux hover smoke test."""
import sys

if "--right" in sys.argv:
    print("Neighbor pane - this text must not enter the formula.")
    print("Keep each pane separate.")
    print(r"Different formula: $z=99$")
else:
    print("MATHPEEK HOVER DEMO")
    print("Move the pointer over any part of a formula; do not select.")
    print()
    print(r"Inline: $e^{i\pi}+1=0$")
    print()
    print("Hard-wrapped command, as seen through tmux:")
    print("$$\\fra")
    print("c{1}{2}+\\sum_{i=1}^{n} i^2$$")
    print()
    print("Multi-line aligned math:")
    print(r"\[")
    print(r"\begin{aligned}")
    print(r"a &= b+c \\")
    print(r"x &= \sqrt{\frac{1}{2}}")
    print(r"\end{aligned}")
    print(r"\]")
    print()
    print("Chinese context: 中文说明，后面是 $x^2+y^2=1$。")
input("\nPress Enter to close this demo pane. ")
