import Foundation

let lines = [
    "",
    "  MATH PEEK DEMO",
    "  Hover to read LaTeX. No selection. No copy and paste.",
    "",
    "  01  Euler's identity",
    #"      $e^{i\pi}+1=0$"#,
    "", "", "",
    "  02  Kalman gain",
    #"      $$\boxed{K = \frac{P}{P+R}}$$"#,
    "", "", "",
    "  03  Motion prediction",
    #"      $$\begin{aligned}v_{\mathrm{pred}}&=v+at\\x_{\mathrm{pred}}&=x+vt\end{aligned}$$"#,
    "", "", "", "", "", ""
]
print("\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\n"))
