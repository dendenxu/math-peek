import AppKit

enum TerminalDiscovery {
    static let catalog: [(bundleIdentifier: String, displayName: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("org.alacritty", "Alacritty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("co.zeit.hyper", "Hyper")
    ]
    static let knownBundleIdentifiers = Set(catalog.map(\.bundleIdentifier))

    static func installedApplications() -> [HoverApplication] {
        catalog.compactMap { candidate in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleIdentifier),
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == candidate.bundleIdentifier else { return nil }
            let name = ["CFBundleDisplayName", "CFBundleName"].compactMap { key -> String? in
                guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }.first ?? candidate.displayName
            return HoverApplication(bundleIdentifier: candidate.bundleIdentifier, displayName: name, enabled: true)
        }
    }
}
