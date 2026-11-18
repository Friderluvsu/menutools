import AppKit
import SwiftUI

/// Section title with the installed app's icon (SF Symbol if that app is missing).
struct SessionCardHeader: View {
    enum Kind {
        case claude, cursor, codex, antigravity
    }

    let kind: Kind
    var tally: SessionStatusTally = SessionStatusTally()
    /// The marks filter the card's rows; the double check marks every finish checked.
    var listState: SessionListState? = nil
    var onCheckAll: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            AppIconImage(names: kind.appNames, bundleIds: kind.bundleIds, fallbackSymbol: kind.fallbackSymbol)
            Text(kind.title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            if let listState {
                SessionStatusMarks(
                    tally: tally, selected: listState.filter(for: kind, tally: tally),
                    onSelect: { listState.toggleFilter($0, for: kind, tally: tally) })
            } else {
                SessionStatusMarks(tally: tally)
            }
            if let onCheckAll, tally.ended > 0 {
                Button(action: onCheckAll) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SessionStatusTone.ended.color)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
                .help("Mark all checked")
                .accessibilityLabel("Mark all \(kind.title) checked")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let detail = tally.spoken
        return detail.isEmpty ? kind.title : "\(kind.title), \(detail)"
    }
}

struct AppIconImage: View {
    let names: [String]
    let bundleIds: [String]
    var size: CGFloat = 16
    var fallbackSymbol: String

    var body: some View {
        Group {
            if let image = InstalledAppIcon.image(named: names, bundleIds: bundleIds) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size - 2, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum InstalledAppIcon {
    private static var cache: [String: NSImage] = [:]
    private static var missed: Set<String> = []

    static func image(named names: [String], bundleIds: [String]) -> NSImage? {
        let key = (bundleIds + names).joined(separator: "\u{1e}")
        if let cached = cache[key] { return cached }
        if missed.contains(key) { return nil }
        if let image = lookup(names: names, bundleIds: bundleIds) {
            cache[key] = image
            return image
        }
        missed.insert(key)
        return nil
    }

    private static func lookup(names: [String], bundleIds: [String]) -> NSImage? {
        let workspace = NSWorkspace.shared
        let dirs = [
            "/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for name in names {
            for dir in dirs {
                let path = (dir as NSString).appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: path) {
                    return workspace.icon(forFile: path)
                }
            }
        }
        for id in bundleIds {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                return workspace.icon(forFile: url.path)
            }
        }
        for app in workspace.runningApplications {
            if let id = app.bundleIdentifier, bundleIds.contains(id), let icon = app.icon {
                return icon
            }
            if let name = app.localizedName,
                names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                let icon = app.icon
            {
                return icon
            }
        }
        return nil
    }
}

extension SessionCardHeader.Kind {
    var title: String {
        switch self {
        case .claude: return "Claude Sessions"
        case .cursor: return "Cursor Sessions"
        case .codex: return "Codex Sessions"
        case .antigravity: return "Antigravity Sessions"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .claude: return "terminal"
        case .cursor: return "cursorarrow"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.forward.circle"
        }
    }

    var appNames: [String] {
        switch self {
        case .claude: return ["Claude"]
        case .cursor: return ["Cursor"]
        case .codex: return ["ChatGPT", "Codex"]
        case .antigravity: return ["Antigravity", "Antigravity IDE"]
        }
    }

    var bundleIds: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.todesktop.230313mhl4w4u92"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .antigravity: return ["com.google.antigravity", "com.google.antigravity-ide"]
        }
    }
}
