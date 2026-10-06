import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

extension MathPeek {
    func applicationWillTerminate(_ notification: Notification) {
        followTimer?.invalidate()
        settingsTimer?.invalidate()
        hover.timer?.invalidate()
        captureGeneration += 1
        captureRequest = nil
        if let hotkey { UnregisterEventHotKey(hotkey) }
    }
}
