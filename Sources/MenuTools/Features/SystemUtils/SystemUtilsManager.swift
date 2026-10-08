import AppKit
import Combine
import Foundation

@MainActor
final class SystemUtilsManager: ObservableObject {
    @Published var isHiddenFilesShown: Bool = false
    @Published var isDockAutohideEnabled: Bool = false
    @Published var isActionRunning: Bool = false
    @Published var lastActionResult: String?

    init() {
        checkCurrentStates()
    }

    func checkCurrentStates() {
        let (hiddenOut, _) = Shell.run("defaults read com.apple.finder AppleShowAllFiles 2>/dev/null")
        isHiddenFilesShown = (hiddenOut == "1" || hiddenOut.lowercased() == "true" || hiddenOut.lowercased() == "yes")

        let (dockOut, _) = Shell.run("defaults read com.apple.dock autohide 2>/dev/null")
        isDockAutohideEnabled = (dockOut == "1" || dockOut.lowercased() == "true")
    }

    func ejectAllDisks() {
        runAction("Ejecting all external disks...") {
            let (output, _) = Shell.run(
                """
                osascript -e '
                tell application "Finder"
                    eject (every disk whose ejectable is true)
                end tell'
                """)
            return output.isEmpty ? "All external disks ejected successfully" : output
        }
    }

    func autoResetGoogleDriveHelper() {
        Task.detached(priority: .utility) {
            _ = Shell.run("pluginkit -e ignore -i com.google.drivefs.finderhelper.findersync 2>/dev/null")
        }
    }

    func resetGoogleDriveHelper() {
        runAction("Resetting Google Drive FinderSync...") {
            let (output, code) = Shell.run("pluginkit -e ignore -i com.google.drivefs.finderhelper.findersync")
            if code == 0 {
                return "Google Drive FinderSync ignored"
            } else {
                return output.isEmpty ? "Executed pluginkit command" : output
            }
        }
    }

    func emptyTrash() {
        runAction("Emptying Trash...") {
            Shell.run("osascript -e 'tell application \"Finder\" to empty trash' 2>/dev/null")
            return "Trash emptied"
        }
    }

    func flushDNS() {
        runAction("Flushing DNS Cache...") {
            Shell.run("sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null")
            return "DNS Cache flushed"
        }
    }

    func toggleHiddenFiles() {
        let newState = !isHiddenFilesShown
        runAction(newState ? "Showing hidden files..." : "Hiding hidden files...") {
            Shell.run(
                "defaults write com.apple.finder AppleShowAllFiles -bool \(newState ? "true" : "false"); killall Finder"
            )
            return newState ? "Hidden files are now visible" : "Hidden files are now hidden"
        }
        isHiddenFilesShown = newState
    }

    func toggleDockAutohide() {
        let newState = !isDockAutohideEnabled
        runAction(newState ? "Enabling Dock autohide..." : "Disabling Dock autohide...") {
            Shell.run("defaults write com.apple.dock autohide -bool \(newState ? "true" : "false"); killall Dock")
            return newState ? "Dock autohide enabled" : "Dock autohide disabled"
        }
        isDockAutohideEnabled = newState
    }

    func lockScreen() {
        Shell.run("pmset displaysleepnow")
    }

    private func runAction(_ title: String, action: @Sendable @escaping () -> String) {
        isActionRunning = true
        lastActionResult = title

        Task.detached {
            let result = action()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isActionRunning = false
                self.lastActionResult = result

                // Clear notification message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.lastActionResult == result {
                        self.lastActionResult = nil
                    }
                }
            }
        }
    }
}
