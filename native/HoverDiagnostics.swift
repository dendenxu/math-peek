import AppKit
import ApplicationServices

/// Maps internal stages to user-facing status and writes metadata-only diagnostics.
/// Terminal text and formula source never enter this component.
final class HoverDiagnostics {
    struct Context {
        let enabled: Bool
        let trusted: Bool
        let hasAllowedApplications: Bool
        let latencyMS: Double
        let popupSize: NSSize
    }

    private let writer = DiagnosticWriter(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/hover-status.json"))
    private let report: (String) -> Void
    private(set) var lastStage = ""
    private(set) var captureIssue: String?

    init(report: @escaping (String) -> Void) { self.report = report }

    func reset() { lastStage = ""; captureIssue = nil }

    func update(_ stage: String, context: Context) {
        guard stage != lastStage else { return }
        lastStage = stage
        let previousIssue = captureIssue
        switch stage {
        case "no-range-for-position": captureIssue = "Terminal does not expose pointer-to-text mapping"
        case "no-text-area": captureIssue = "No accessible terminal text under pointer"
        case "empty-ax-text": captureIssue = "Terminal does not expose visible text"
        case "cmux-connection-required": captureIssue = "cmux: run math-peek connect cmux in a local pane"
        case "cmux-connection-unavailable": captureIssue = "cmux connection unavailable; reconnect from a local pane"
        case "cmux-no-geometry", "cmux-grid-unavailable": captureIssue = "cmux does not provide a usable viewport grid"
        case "ghostty-connection-required": captureIssue = "Ghostty: run math-peek connect ghostty in this pane"
        case "ghostty-reconnect-required": captureIssue = "Ghostty geometry changed; run math-peek connect ghostty again"
        case "ghostty-layout-unsupported": captureIssue = "Ghostty experimental hover: this layout cannot be reconstructed"
        default: captureIssue = nil
        }
        if captureIssue != previousIssue { report(message(for: stage, context: context)) }
        guard Bundle.main.bundleIdentifier == "local.mathpeek.preview" else { return }
        let state: [String: Any] = [
            "stage": stage, "trusted": context.trusted, "enabled": context.enabled,
            "last_popup_latency_ms": Int(context.latencyMS), "renderer": "swiftmath",
            "popup_width": Int(context.popupSize.width), "popup_height": Int(context.popupSize.height),
            "time": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { writer.write(data) }
    }

    private func message(for stage: String, context: Context) -> String {
        switch stage {
        case "ghostty-connection-required":
            return "Ghostty 实验悬停：请在当前本地窗格运行 math-peek connect ghostty，连接后无需刷新。"
        case "ghostty-reconnect-required":
            return "Ghostty 的字体、屏幕缩放或网格发生变化；请在当前窗格重新运行 math-peek connect ghostty。"
        case "ghostty-layout-unsupported":
            return "Ghostty 实验模式无法确定当前换行或字符宽度，已跳过本次预览。"
        case "cmux-connection-required":
            return "请在 cmux 的本地终端中运行 math-peek connect cmux；连接后无需刷新或重启。"
        case "cmux-connection-unavailable":
            return "cmux 连接暂不可用。确认 cmux 正在运行；若持续失败，请在本地窗格重新运行 math-peek connect cmux。"
        case "cmux-no-geometry", "cmux-grid-unavailable":
            return "cmux 没有返回可用的字符网格或位置；请检查版本，并在普通终端窗格内尝试。"
        case "no-range-for-position":
            return "此终端没有提供鼠标到文字的位置映射，无法自动悬停预览。"
        case "no-text-area":
            return "鼠标所在位置没有可读取的终端文字；应用需要提供系统辅助功能文本接口。"
        case "empty-ax-text":
            return "此终端没有提供可读取的可见文字，暂时无法自动悬停预览。可选中文字后使用阅读窗口。"
        default:
            return !context.enabled ? "悬停预览已暂停。" : !context.trusted
                ? "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。"
                : !context.hasAllowedApplications ? "请在 Terminal Apps 菜单中添加或启用终端应用。"
                : "悬停已开启：鼠标移到已添加终端的公式上即可预览。"
        }
    }
}
