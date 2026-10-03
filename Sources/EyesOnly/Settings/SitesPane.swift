import AppKit

@MainActor
final class SitesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var view = NSStackView()
    private let table = NSTableView()
    private let field = NSTextField()
    private var sites = Settings.sites
    private let activeOnly = NSButton(checkboxWithTitle: "Capture a protected tab's window only while that tab is active", target: nil, action: nil)
    var onChange: () -> Void = {}
    var onActiveOnlyChange: (Bool) -> Void = { _ in }

    override init() {
        super.init()
        field.placeholderString = "example.com or example.com/path"
        field.target = self; field.action = #selector(add)
        let addButton = sized(NSButton(title: "Add", target: self, action: #selector(add)), width: 104)
        let column0 = NSTableColumn(identifier: .init("site")); column0.width = contentWidth - 20
        table.addTableColumn(column0)
        table.headerView = nil
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        activeOnly.target = self; activeOnly.action = #selector(activeOnlyChanged)
        let remove = sized(NSButton(title: "Remove", target: self, action: #selector(removeSelected)), width: 104)

        let intro = label("Tabs showing these sites are protected automatically — no need to tick them. mail.google.com covers that site and its subdomains; bank.com/accounts only pages under that path.", size: 12)
        intro.textColor = .secondaryLabelColor
        view = column([
            label("Protected sites", bold: true),
            intro,
            row([sized(field, width: contentWidth - 8 - 104), addButton]),
            sized(scroll, width: contentWidth, height: 148),
            remove,
            activeOnly,
            note("⚠︎ Then nothing of that window is captured while you're on other tabs — but you'll see black for a moment each time you switch to the protected tab.", color: .systemOrange),
        ], spacing: 8)
        view.setCustomSpacing(4, after: view.arrangedSubviews[0])
        view.setCustomSpacing(20, after: remove)
        view.setCustomSpacing(4, after: activeOnly)
    }

    func reload() { sites = Settings.sites; table.reloadData(); activeOnly.state = Settings.captureOnlyActiveTab ? .on : .off }
    @objc private func activeOnlyChanged() {
        Settings.captureOnlyActiveTab = activeOnly.state == .on
        onActiveOnlyChange(activeOnly.state == .on)
    }

    @objc private func add() {
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = ""
        guard !s.isEmpty, !sites.contains(s) else { return }
        sites.append(s); save()
    }
    @objc private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        sites = sites.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
    }
    func addSite(_ host: String) { if !sites.contains(host) { sites.append(host); save() } }
    private func save() { Settings.sites = sites; table.reloadData(); onChange() }

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: sites[row]); cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }
}
