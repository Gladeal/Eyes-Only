import AppKit

@MainActor
final class AppsPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct App { let name: String; let id: String; let path: String }
    private(set) var view = NSStackView()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let onlyTicked = NSButton(checkboxWithTitle: "Show only protected apps", target: nil, action: nil)
    private var all: [App] = []
    private var shown: [App] = []
    private var icons: [String: NSImage] = [:]
    var ticked: () -> Set<String> = { [] }
    var setTicked: (String, Bool) -> Void = { _, _ in }

    override init() {
        super.init()
        search.placeholderString = "Search apps"
        search.delegate = self
        onlyTicked.target = self; onlyTicked.action = #selector(filter)

        let column0 = NSTableColumn(identifier: .init("app")); column0.width = contentWidth - 20
        table.addTableColumn(column0)
        table.headerView = nil
        table.rowHeight = 26
        table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        view = column([
            label("Tick an app to protect every one of its windows automatically, as soon as it opens — now and after a restart.", size: 12),
            row([sized(search, width: 300), onlyTicked], spacing: 16),
            sized(scroll, width: contentWidth, height: 334),
        ])
    }

    func reload() {
        if all.isEmpty { all = Self.installedApps() }
        filter()
    }

    /// Everything in the usual app folders, plus anything running from elsewhere.
    static func installedApps() -> [App] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0) }
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var urls = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "app" }
        urls += NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        let me = Bundle.main.bundleIdentifier ?? ""
        var seen = Set<String>(), apps: [App] = []
        for u in urls {
            guard let id = Bundle(url: u)?.bundleIdentifier, !seen.contains(id), id != me, !id.hasPrefix("com.eyesonly.") else { continue }
            seen.insert(id)
            apps.append(App(name: fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), id: id, path: u.path))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @objc private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let t = ticked()
        shown = all.filter { (q.isEmpty || $0.name.lowercased().contains(q)) && (onlyTicked.state == .off || t.contains($0.id)) }
        table.reloadData()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = shown[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 26))
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
        box.frame = NSRect(x: 6, y: 3, width: 22, height: 20)
        box.state = ticked().contains(app.id) ? .on : .off
        box.identifier = .init(app.id)
        cell.addSubview(box)
        let icon = NSImageView(frame: NSRect(x: 32, y: 3, width: 20, height: 20))
        if icons[app.id] == nil { let i = NSWorkspace.shared.icon(forFile: app.path); i.size = NSSize(width: 20, height: 20); icons[app.id] = i }
        icon.image = icons[app.id]
        cell.addSubview(icon)
        let name = NSTextField(labelWithString: app.name)
        name.frame = NSRect(x: 58, y: 4, width: 470, height: 18)
        name.lineBreakMode = .byTruncatingTail
        cell.addSubview(name)
        return cell
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        setTicked(id, sender.state == .on)
        if onlyTicked.state == .on { filter() }
    }
}
