import AppKit

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    enum Pane: Int { case general, apps, browser }
    let window: NSWindow
    let general = GeneralPane()
    let apps = AppsPane()
    let sites = SitesPane()
    let browser = BrowserPane()
    private var panes: [NSView] = []
    private var current: NSView?
    /// The native settings toolbar (icon tabs), like Apple's own apps.
    private let tabs: [(id: NSToolbarItem.Identifier, title: String, symbol: String)] = [
        (.init("general"), "General", "gear"),
        (.init("apps"), "Apps", "square.grid.2x2"),
        (.init("browser"), "Browser", "globe"),
    ]

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        // Open on the Space you're on, not the one it was first shown on.
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        // Browser: the extension on top, the protected sites under it.
        panes = [page(general.view), page(apps.view), page(browser.view, separator(), sites.view)]
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        select(0)
    }

    func show(_ pane: Pane? = nil) {
        if let pane { select(pane.rawValue) }
        general.reload(); apps.reload(); sites.reload(); browser.start()
        present(window)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map(\.id) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map(\.id) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(picked(_:))
        return item
    }
    @objc private func picked(_ sender: NSToolbarItem) {
        if let i = tabs.firstIndex(where: { $0.id == sender.itemIdentifier }) { select(i) }
    }

    /// Like System Settings: each tab is as tall as its content, and the window takes that size, keeping its
    /// top edge in place.
    func select(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        window.toolbar?.selectedItemIdentifier = tabs[index].id
        window.title = tabs[index].title
        current?.removeFromSuperview()
        let pane = panes[index]
        let size = pane.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = window.isVisible ? NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height) : window.frame.origin
        window.setFrame(frame, display: true, animate: window.isVisible)
        pane.frame = NSRect(origin: .zero, size: size)
        window.contentView!.addSubview(pane)
        current = pane
    }

    /// A tab's page: its parts top to bottom, with the window's margins around them.
    private func page(_ parts: NSView...) -> NSView {
        let page = column(parts, spacing: 20)
        page.edgeInsets = NSEdgeInsets(top: 20, left: 40, bottom: 20, right: 40)
        return page
    }

    func windowWillClose(_ notification: Notification) { browser.stop() }
}

/// Shows a utility window in this menu-bar-only app (which has no Dock icon and is never "active" by itself).
@MainActor func present(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
}

// MARK: Layout — panes are columns of rows; Auto Layout works out the sizes.

/// Settings content is this wide; text wraps to it.
let contentWidth: CGFloat = 560

/// Rows top to bottom, `contentWidth` wide.
@MainActor func column(_ rows: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

/// Views side by side.
@MainActor func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

@MainActor func label(_ text: String, size: CGFloat = 13, bold: Bool = false, width: CGFloat = contentWidth) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.isSelectable = false   // explanations, not content
    l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    l.preferredMaxLayoutWidth = width
    return l
}

/// An explanation under a checkbox, lined up with the checkbox's title.
@MainActor func note(_ text: String, color: NSColor = .secondaryLabelColor) -> NSView {
    let l = label(text, size: 12, width: contentWidth - 22)
    l.textColor = color
    let indented = row([l])
    indented.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
    return indented
}

@MainActor func separator() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    return sized(line, width: contentWidth)
}

/// Fixes a view's width (and height, if given).
@MainActor @discardableResult func sized<V: NSView>(_ view: V, width: CGFloat, height: CGFloat? = nil) -> V {
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    return view
}
