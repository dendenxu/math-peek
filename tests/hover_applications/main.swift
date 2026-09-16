import Foundation

let suite = "local.mathpeek.tests.hover-applications.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}
func reload() -> HoverApplications { HoverApplications(defaults: defaults) }

let apps = reload()
check(apps.enabledBundleIdentifiers == ["com.googlecode.iterm2"], "first launch enables iTerm2")
check(apps.add(bundleIdentifier: "dev.example.terminal", displayName: "My Terminal"), "add custom terminal")
check(reload().applications == apps.applications, "added applications survive reload")
check(apps.add(bundleIdentifier: "dev.example.terminal", displayName: "Renamed Terminal"), "add duplicate updates entry")
check(apps.applications.count == 2 && apps.applications.last?.displayName == "Renamed Terminal", "duplicate is not appended")
apps.setEnabled(false, for: "dev.example.terminal")
check(!reload().enabledBundleIdentifiers.contains("dev.example.terminal"), "disabled custom application survives reload")
apps.setEnabled(false, for: "com.googlecode.iterm2")
check(reload().enabledBundleIdentifiers.isEmpty && reload().applications.count == 2, "disabling all persists")
apps.add(bundleIdentifier: "dev.example.terminal", displayName: "My Terminal")
check(reload().enabledBundleIdentifiers == ["dev.example.terminal"], "adding saved application enables it")
apps.remove(bundleIdentifier: "com.googlecode.iterm2")
apps.remove(bundleIdentifier: "dev.example.terminal")
check(reload().applications.isEmpty, "removing all persists without default recovery")
check(!apps.add(bundleIdentifier: " \n", displayName: "Invalid"), "empty identifier rejected")
check(!apps.add(bundleIdentifier: "dev.example. terminal", displayName: "Invalid"), "whitespace identifier rejected")
check(!apps.add(bundleIdentifier: "dev.example.\0terminal", displayName: "Invalid"), "control character identifier rejected")
check(reload().applications.isEmpty, "invalid add does not change saved state")
apps.add(bundleIdentifier: " dev.example.terminal ", displayName: " \n")
check(apps.applications.first?.displayName == "dev.example.terminal", "normalization and empty name fallback")
apps.setEnabled(false, for: "missing.application")
check(apps.enabledBundleIdentifiers == ["dev.example.terminal"], "unknown toggle leaves existing state")

defaults.set([
    ["bundleIdentifier": "dev.valid.terminal", "displayName": "First", "enabled": false],
    ["bundleIdentifier": "dev.valid.terminal", "displayName": "Duplicate", "enabled": true],
    ["bundleIdentifier": "dev.other.terminal", "displayName": "Other", "enabled": true],
    ["bundleIdentifier": "  ", "displayName": "Empty", "enabled": true],
    ["bundleIdentifier": "dev.missing.flag", "displayName": "Missing"],
    ["bundleIdentifier": "dev.invalid.flag", "displayName": "Invalid", "enabled": "true"],
    ["bundleIdentifier": 42, "displayName": "Number", "enabled": true],
    "invalid entry"
] as [Any], forKey: HoverApplications.storageKey)
let parsed = reload()
check(parsed.applications.count == 2, "malformed saved entries discarded and identifiers deduplicated")
check(parsed.enabledBundleIdentifiers == ["dev.other.terminal"], "first duplicate wins without enabling disabled app")
check(parsed.applications.first?.displayName == "First", "saved application order retained")
defaults.set("corrupt", forKey: HoverApplications.storageKey)
check(reload().applications.isEmpty, "invalid saved list does not restore default")
defaults.set([], forKey: HoverApplications.storageKey)
check(reload().applications.isEmpty, "explicit empty list does not restore default")

defaults.removePersistentDomain(forName: suite)
let discovered = reload()
let terminal = HoverApplication(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", enabled: false)
let custom = HoverApplication(bundleIdentifier: "dev.custom.terminal", displayName: "Custom Terminal", enabled: true)
check(!discovered.hasLegacyEmptySelection, "fresh install does not suppress automatic discovery")
check(discovered.discover([terminal, terminal]), "new installed terminal is discovered")
check(discovered.applications.count == 2 && discovered.enabledBundleIdentifiers.contains(terminal.bundleIdentifier), "discovery deduplicates and enables new terminal")
check(reload().applications == discovered.applications, "discovery is persisted")
check(!discovered.discover([terminal]), "repeat discovery reports no change")
discovered.setEnabled(false, for: terminal.bundleIdentifier)
check(!discovered.discover([terminal]) && !reload().enabledBundleIdentifiers.contains(terminal.bundleIdentifier), "discovery never reenables disabled application")
discovered.remove(bundleIdentifier: terminal.bundleIdentifier)
let afterRemoval = reload()
check(!afterRemoval.discover([terminal]) && !afterRemoval.applications.contains(where: { $0.bundleIdentifier == terminal.bundleIdentifier }), "removed application stays excluded after reload")
check(afterRemoval.discover([custom]), "removal does not exclude other newly discovered applications")
check(afterRemoval.add(bundleIdentifier: terminal.bundleIdentifier, displayName: terminal.displayName), "explicit add overrides removal")
check(reload().enabledBundleIdentifiers.contains(terminal.bundleIdentifier), "explicit add enables removed application")
check(!(defaults.stringArray(forKey: HoverApplications.exclusionsKey) ?? []).contains(terminal.bundleIdentifier), "explicit add clears persisted exclusion")
for application in afterRemoval.applications { afterRemoval.remove(bundleIdentifier: application.bundleIdentifier) }
let cleared = reload()
check(cleared.applications.isEmpty && !cleared.discover([terminal, custom]), "removed whole list stays empty across discovery")
check(!cleared.hasLegacyEmptySelection, "new empty selection is represented by exclusions")
check(!cleared.discover([HoverApplication(bundleIdentifier: "\n", displayName: "Invalid", enabled: true)]), "invalid discovery identifier rejected")

defaults.removePersistentDomain(forName: suite)
defaults.set([], forKey: HoverApplications.storageKey)
let legacyEmpty = reload()
check(legacyEmpty.hasLegacyEmptySelection && legacyEmpty.applications.isEmpty, "legacy empty selection signals disabled discovery default")
check(legacyEmpty.discover([terminal]), "explicitly enabled discovery can populate legacy empty selection")
check(!reload().hasLegacyEmptySelection, "discovery migrates legacy empty selection")
defaults.removePersistentDomain(forName: suite)
defaults.set("corrupt", forKey: HoverApplications.storageKey)
check(reload().hasLegacyEmptySelection, "invalid legacy selection also suppresses default discovery")
defaults.set([" com.apple.Terminal ", "\n", 42] as [Any], forKey: HoverApplications.exclusionsKey)
let malformed = reload()
check(!malformed.discover([terminal]), "saved exclusions normalize identifiers and skip malformed entries")

print("Hover applications: \(checks - failures)/\(checks) passed")
defaults.removePersistentDomain(forName: suite)
exit(failures == 0 ? 0 : 1)
