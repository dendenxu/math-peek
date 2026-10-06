import Foundation

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--neighbor") || arguments.contains("--right") || arguments.contains("--bottom") {
    print("MATHPEEK SYNTHETIC NEIGHBOR LOGS")
    for number in 0..<36 { print(String(format: "agent %02d │ tool result │ unrelated $z=99$ │ done", number)) }
} else if arguments.contains("--regression") {
    print("MATHPEEK REGRESSION DEMO")
    print("Hover every source row; no selection is needed.\n")
    print("Delimited velocity:")
    print("$$")
    print(#"v_{\mathrm{pred}} ="#)
    print(#"v_{\mathrm{prev}} + a_{\mathrm{world}}\Delta t"#)
    print("$$\n")
    print("Raw velocity (tmux wraps this line):")
    print(#"v_{\mathrm{pred}} = v_{\mathrm{prev}} + a_{\mathrm{world}}\Delta t"#)
    print("\nOne-column matrix (single slash rows):")
    print(#"\["#); print(#"\begin{bmatrix}"#); print(#"v_x \"#); print(#"v_y \"#); print("v_z"); print(#"\end{bmatrix}"#); print(#"\]"#)
    print("\nAligned (broken spacing command):")
    print(#"\["#); print(#"\begin{aligned}"#)
    print(#"p_{\mathrm{pred}} &= p_{\mathrm{prev}} + v_{\mathrm{prev}}\Delta t \[8pt]"#)
    print(#"v_{\mathrm{pred}} &= v_{\mathrm{prev}} + a_{\mathrm{world}}\Delta t \[8pt]"#)
    print(#"a_{\mathrm{world}} &= R(q)a_{\mathrm{body}} - g"#); print(#"\end{aligned}"#); print(#"\]"#)
    print("\nCodex-prompt display (stripped delimiters):")
    print("› ["); print(#"\theta_{t+\Delta t}"#); print(#"\alpha\theta_{\text{gyro}}"#); print("+"); print(#"(1-\alpha)\theta_{\text{acc}}"#); print("]")
    print("\nMarkdown-heading display (stripped delimiters and heading artifacts):")
    print("# ["); print(#"\theta"#); print(#"# 0.98\times10.6^\circ"#); print("+"); print(#"0.02\times9^\circ"#); print(#"10.568^\circ"#); print("]")
    print("\nPlain stripped display:"); print("["); print(#"a\longrightarrow v\longrightarrow p"#); print("]")
    print("\nStripped inline matrix:")
    print(#"(i) (j) (42) (3.14) (α) (x') (x_i) (x^2) (T^{-1})"#)
    print(#"(W^Q_l) (W_{Q,video}) (W_{Q,audio}) (c_{\mathrm{ref}}) (10.6^\circ)"#)
    print(#"(x+y) (a/b) (\frac{a}{b}) (f(x)) (R(p_i)q_i) (\langle x,y\rangle)"#)
    print("\nEND REGRESSION DEMO")
} else if arguments.contains("--full") || arguments.contains("--kalman") ||
          arguments.contains("--matrices") || arguments.contains("--boxed") {
    let mode = arguments.contains("--boxed") ? "boxed" : arguments.contains("--matrices") ? "matrices" : "kalman"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/full_formula_fixtures.json")
    let data = try Data(contentsOf: url)
    let fixtures = try JSONDecoder().decode([String: String].self, from: data)
    guard let source = fixtures[mode] else { fatalError("missing fixture \(mode)") }
    print("MATHPEEK FULL FORMULA DEMO")
    print("Fixture mode: \(mode)")
    print("Tiny reset: $x$\n\nFull formula:")
    print(source.trimmingCharacters(in: .whitespacesAndNewlines))
    print("END FULL FORMULA")
} else {
    print("MATHPEEK HOVER DEMO")
    print("Move the pointer over any part of a formula; do not select.\n")
    print(#"Inline: $e^{i\pi}+1=0$"#)
    print("\nHard-wrapped command, as seen through tmux:")
    print(#"$$\fra"#); print(#"c{1}{2}+\sum_{i=1}^{n} i^2$$"#)
    print("\nMulti-line aligned math:")
    print(#"\["#); print(#"\begin{aligned}"#); print(#"a &= b+c \\"#); print(#"x &= \sqrt{\frac{1}{2}}"#); print(#"\end{aligned}"#); print(#"\]"#)
    print("\nChinese context: 中文说明，后面是 $x^2+y^2=1$。")
}
print("\nPress Enter to close this isolated fixture.")
_ = readLine()
