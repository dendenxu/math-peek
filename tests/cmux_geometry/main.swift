import Foundation
import CoreGraphics

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

let windowID = "27BCD9F1-B4A0-46E7-95FC-562CD1B9F902"
let workspaceID = "8CDE2A40-D347-46F3-A1CF-F9FBA921854B"
let paneID = "0E10C902-4ACF-4977-90B7-DFBA985A5AD9"
let surfaceID = "9E353044-4381-4AC0-B4D7-97632213DDC9"
func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
    ["x": x, "y": y, "width": width, "height": height]
}
var terminal: [String: Any] = [
    "window_id": windowID, "workspace_id": workspaceID, "pane_id": paneID, "surface_id": surfaceID,
    "workspace_selected": true, "surface_selected_in_pane": true, "hosted_view_visible_in_ui": true,
    "hosted_view_hidden_or_ancestor_hidden": false, "window_visible": true, "runtime_surface_ready": true,
    "window_frame": rectangle(-1500, 100, 1000, 700),
    "hosted_view_frame_in_window": rectangle(200, 50, 780, 600)
]
let area = CGRect(x: -1299, y: 151, width: 776, height: 596)
let surface = CmuxHoverSource.surface(in: ["terminals": [terminal]], area: area, screenTop: 900)
check(surface?.surfaceID == surfaceID, "real debug.terminals schema identifies one visible surface")
check(surface?.hostedFrame == CGRect(x: -1300, y: 150, width: 780, height: 600),
      "window-local bottom-left coordinates convert to global AX top-left coordinates")
check(surface?.windowID == windowID && surface?.workspaceID == workspaceID && surface?.paneID == paneID,
      "window, workspace, and pane UUIDs remain bound to matched surface")
check(CmuxHoverSource.surface(in: ["terminals": [terminal, terminal]], area: area, screenTop: 900) == nil,
      "overlapping candidate surfaces fail closed")
check(CmuxHoverSource.surface(in: ["terminals": [terminal]],
                              area: CGRect(x: -1300, y: 149, width: 780, height: 610), screenTop: 900) == nil,
      "whole pane including tab chrome cannot substitute for terminal text area")
for key in ["workspace_selected", "surface_selected_in_pane", "hosted_view_visible_in_ui",
            "window_visible", "runtime_surface_ready"] {
    var hidden = terminal
    hidden[key] = false
    check(CmuxHoverSource.surface(in: ["terminals": [hidden]], area: area, screenTop: 900) == nil,
          "nonvisible or inactive surface is excluded: \(key)")
}
var hidden = terminal
hidden["hosted_view_hidden_or_ancestor_hidden"] = true
check(CmuxHoverSource.surface(in: ["terminals": [hidden]], area: area, screenTop: 900) == nil,
      "hidden ancestor excludes otherwise selected surface")
var invalid = terminal
invalid["pane_id"] = NSNull()
check(CmuxHoverSource.surface(in: ["terminals": [invalid]], area: area, screenTop: 900) == nil,
      "unmapped or remote pane cannot borrow a neighboring surface")
invalid = terminal
invalid["window_frame"] = rectangle(-1500, .nan, 1000, 700)
check(CmuxHoverSource.surface(in: ["terminals": [invalid]], area: area, screenTop: 900) == nil,
      "nonfinite window geometry is rejected")
var above = terminal
above["window_frame"] = rectangle(200, 1100, 1000, 700)
check(CmuxHoverSource.surface(in: ["terminals": [above]],
                              area: CGRect(x: 401, y: -849, width: 776, height: 596), screenTop: 900)?.hostedFrame ==
      CGRect(x: 400, y: -850, width: 780, height: 600),
      "display above the primary display retains negative AX y")

let pane: [String: Any] = ["id": paneID, "selected_surface_id": surfaceID,
                           "columns": 80, "rows": 30,
                           "cell_width_px": 17, "cell_height_px": 33,
                           "cell_width_points": 8.5, "cell_height_points": 16.5,
                           "pixel_frame": rectangle(0, 0, 1000, 800)]
func layout(_ panes: [[String: Any]]) -> [String: Any] {
    ["window_id": windowID, "workspace_id": workspaceID, "panes": panes]
}
let metrics = CmuxHoverSource.metrics(in: layout([pane]), surface: surface!)
check(metrics?.columns == 80 && metrics?.rows == 30 && metrics?.cellSize == CGSize(width: 8.5, height: 16.5),
      "pane.list uses calibrated point cell sizes and ignores chrome frame")
var wrong = pane
wrong["selected_surface_id"] = UUID().uuidString
check(CmuxHoverSource.metrics(in: layout([wrong]), surface: surface!) == nil,
      "tab switch invalidates pane metrics")
check(CmuxHoverSource.metrics(in: layout([pane, pane]), surface: surface!) == nil,
      "duplicate pane identity is rejected")
var differentWorkspace = layout([pane])
differentWorkspace["workspace_id"] = UUID().uuidString
check(CmuxHoverSource.metrics(in: differentWorkspace, surface: surface!) == nil,
      "workspace switch invalidates pane metrics")
var differentWindow = layout([pane])
differentWindow["window_id"] = UUID().uuidString
check(CmuxHoverSource.metrics(in: differentWindow, surface: surface!) == nil,
      "window switch invalidates pane metrics")
for (key, value) in [("columns", 0 as Any), ("rows", Int.max as Any),
                     ("cell_width_points", 0 as Any), ("cell_height_points", Double.infinity as Any),
                     ("cell_width_points", true as Any)] {
    var invalid = pane
    invalid[key] = value
    check(CmuxHoverSource.metrics(in: layout([invalid]), surface: surface!) == nil,
          "invalid grid metric is rejected: \(key)")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
