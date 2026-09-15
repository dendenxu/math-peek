import Foundation

struct HoverApplication: Equatable {
    let bundleIdentifier: String
    var displayName: String
    var enabled: Bool
}

final class HoverApplications {
    static let storageKey = "hoverApplications"
    private let defaults: UserDefaults
    private(set) var applications: [HoverApplication]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            applications = [HoverApplication(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2", enabled: true)]
            return
        }
        // A saved empty or invalid list must not silently enable an application.
        var seen = Set<String>()
        applications = (stored as? [Any] ?? []).compactMap { item in
            guard let entry = item as? [String: Any],
                  let rawIdentifier = entry["bundleIdentifier"] as? String,
                  let identifier = Self.validIdentifier(rawIdentifier),
                  let name = entry["displayName"] as? String,
                  let enabled = entry["enabled"] as? Bool,
                  seen.insert(identifier).inserted else { return nil }
            return HoverApplication(bundleIdentifier: identifier, displayName: Self.name(name, fallback: identifier), enabled: enabled)
        }
    }

    var enabledBundleIdentifiers: Set<String> {
        Set(applications.filter(\.enabled).map(\.bundleIdentifier))
    }

    @discardableResult
    func add(bundleIdentifier: String, displayName: String) -> Bool {
        guard let identifier = Self.validIdentifier(bundleIdentifier) else { return false }
        let name = Self.name(displayName, fallback: identifier)
        if let index = applications.firstIndex(where: { $0.bundleIdentifier == identifier }) {
            applications[index].displayName = name
            applications[index].enabled = true
        } else {
            applications.append(HoverApplication(bundleIdentifier: identifier, displayName: name, enabled: true))
        }
        save()
        return true
    }

    func setEnabled(_ enabled: Bool, for bundleIdentifier: String) {
        guard let index = applications.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        applications[index].enabled = enabled
        save()
    }

    func remove(bundleIdentifier: String) {
        applications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        save()
    }

    private func save() {
        defaults.set(applications.map { app -> [String: Any] in
            ["bundleIdentifier": app.bundleIdentifier, "displayName": app.displayName, "enabled": app.enabled]
        }, forKey: Self.storageKey)
    }

    private static func validIdentifier(_ value: String) -> String? {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              identifier.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return identifier
    }

    private static func name(_ value: String, fallback: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }
}
