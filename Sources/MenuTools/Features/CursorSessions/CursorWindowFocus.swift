import Foundation

/// Raises the Cursor window whose title belongs to this project (e.g. `DEVELOPMENT.md — menutools`).
enum CursorWindowFocus {
    static func reveal(project: String, cwd: String) {
        AppWindowFocus.reveal(named: ["Cursor"], bundles: ["Cursor.app"], project: project, cwd: cwd)
    }
}
