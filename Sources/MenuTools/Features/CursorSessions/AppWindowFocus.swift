import AppKit
@preconcurrency import ApplicationServices

/// Raises a regular app window whose title belongs to this project (`file — project`).
enum AppWindowFocus {
    static func reveal(named names: [String], bundles: [String] = [], project: String, cwd: String) {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            if let name = app.localizedName, names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return true
            }
            let bundle = app.bundleURL?.lastPathComponent ?? ""
            return bundles.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame })
        }
        guard let app = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first else { return }
        if AXIsProcessTrusted(), let window = matchingWindow(pid: app.processIdentifier, project: project, cwd: cwd) {
            raise(window)
        }
        app.activate(from: .current)
    }

    /// Brings forward the terminal (or other regular app) that owns this pid.
    static func revealTerminal(for pid: pid_t) {
        var current = pid
        for _ in 0..<8 {
            guard let parent = ProcessLookup.parentPid(current) else { return }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                app.activate(from: .current)
                return
            }
            current = parent
        }
    }

    private static func matchingWindow(pid: pid_t, project: String, cwd: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement]
        else { return nil }

        let needles = matchNames(project: project, cwd: cwd)
        var best: (window: AXUIElement, score: Int)?
        for window in windows {
            var titleValue: AnyObject?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                let title = titleValue as? String
            else { continue }
            let score = matchScore(title: title, needles: needles)
            if score > (best?.score ?? 0) {
                best = (window, score)
            }
        }
        return best?.window
    }

    private static func raise(_ window: AXUIElement) {
        var minimizedValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
            let minimized = minimizedValue as? Bool, minimized
        {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func matchNames(project: String, cwd: String) -> [String] {
        var names: [String] = []
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        for raw in [project, folder] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "—" { names.append(trimmed.lowercased()) }
        }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique
    }

    private static func matchScore(title: String, needles: [String]) -> Int {
        guard !needles.isEmpty else { return 0 }
        let lower = title.lowercased()
        let suffix = projectSuffix(of: lower)
        var best = 0
        for needle in needles {
            if suffix == needle { best = max(best, 3) }
            else if suffix.hasSuffix(needle) { best = max(best, 2) }
            else if lower == needle || lower.hasSuffix(needle) { best = max(best, 2) }
            else if lower.contains(needle) { best = max(best, 1) }
        }
        return best
    }

    private static func projectSuffix(of title: String) -> String {
        for separator in [" — ", " – ", " - "] {
            if let range = title.range(of: separator, options: .backwards) {
                return String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return title
    }
}
