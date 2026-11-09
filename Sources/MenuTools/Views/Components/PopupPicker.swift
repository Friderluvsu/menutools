import AppKit
import SwiftUI

/// One entry of a `PopupPicker`. A `header` row is a non-selectable section title.
struct PopupItem<Value: Hashable>: Identifiable {
    var title: String
    var image: NSImage? = nil
    var value: Value? = nil
    var header = false

    var id: String { header ? "#" + title : title }

    static func header(_ title: String) -> PopupItem { PopupItem(title: title, header: true) }
}

/// An `NSPopUpButton` menu picker. SwiftUI's menu `Picker` builds a hosting view for every row,
/// which costs tens of milliseconds for a long list with images; `NSMenuItem`s are cheap, so
/// Settings opens faster with this for the status-light style and menu bar icon menus.
struct PopupPicker<Value: Hashable>: NSViewRepresentable {
    let items: [PopupItem<Value>]
    @Binding var selection: Value
    var width: CGFloat = 160

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        rebuild(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.itemIDs != items.map(\.id) {
            rebuild(button, context: context)
        } else {
            select(in: button)
        }
    }

    private func rebuild(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.header {
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: item.title))
                } else {
                    let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                continue
            }
            let row = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            row.image = item.image
            row.representedObject = item.value
            menu.addItem(row)
        }
        button.menu = menu
        context.coordinator.itemIDs = items.map(\.id)
        select(in: button)
    }

    private func select(in button: NSPopUpButton) {
        guard let items = button.menu?.items,
            let index = items.firstIndex(where: { ($0.representedObject as? Value) == selection })
        else { return }
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: PopupPicker
        var itemIDs: [String] = []

        init(parent: PopupPicker) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? Value else { return }
            if parent.selection != value { parent.selection = value }
        }
    }
}
