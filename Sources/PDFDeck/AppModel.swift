import SwiftUI
import PDFKit
import Combine
import UniformTypeIdentifiers

struct PDFEntry: Identifiable, Hashable {
    let url: URL
    let root: String              // imported folder this file was found under ("" = loose/top-level)
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isLoose: Bool { root.isEmpty }
}

struct FolderItem: Identifiable {
    let path: String
    var name: String
    var entries: [PDFEntry]
    var id: String { path }
}

enum FocusZone { case sidebar, slides }

enum SidebarTarget: Hashable {
    case folder(String)   // folder path
    case file(String)     // file id (path)
    var rowID: String { switch self { case .folder(let p): "f:" + p; case .file(let i): "x:" + i } }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let pdfView: PDFView = {
        let v = PDFView()
        v.displayMode = .singlePage
        v.displaysPageBreaks = false
        v.autoScales = true
        v.interpolationQuality = .high
        v.backgroundColor = NSColor.textBackgroundColor
        v.minScaleFactor = 0.2              // macOS PDFView handles trackpad pinch natively
        v.maxScaleFactor = 8.0
        return v
    }()
    let thumbs = ThumbCache()

    @Published var folders: [FolderItem] = []
    @Published var looseEntries: [PDFEntry] = []     // externally-opened PDFs, shown at top level
    @Published var selectedID: PDFEntry.ID?
    @Published var document: PDFDocument?
    @Published var currentPage: Int = 0
    @Published var pageCount: Int = 0
    @Published var isLoading: Bool = false

    @Published var focusZone: FocusZone = .sidebar
    @Published var sidebarTarget: SidebarTarget?
    @Published var collapsed: Set<String> = []     // collapsed folder paths

    /// Visible sidebar rows top-to-bottom: loose files (top level), then folder headers + their files.
    var visibleRows: [SidebarTarget] {
        var rows: [SidebarTarget] = []
        for e in looseEntries { rows.append(.file(e.id)) }
        for f in folders {
            rows.append(.folder(f.path))
            if !collapsed.contains(f.path) { for e in f.entries { rows.append(.file(e.id)) } }
        }
        return rows
    }

    private var rootFolders: [String] = []          // ordered imported folder paths
    private var folderNames: [String: String] = [:] // path -> custom display name
    private var lastPage: [String: Int] = [:]       // file path -> page index
    private var loadToken = 0

    private let kFolders = "importedFolders"
    private let kNames = "folderNames"
    private let kLastPages = "lastPages"
    private let kLoose = "looseFiles"
    private let kClaimedPDF = "didClaimPDFDefault"

    /// All files in display order (loose first, then folders) — used for keyboard file stepping.
    var orderedEntries: [PDFEntry] { looseEntries + folders.flatMap { $0.entries } }

    init() {
        let d = UserDefaults.standard
        rootFolders = d.stringArray(forKey: kFolders) ?? []
        folderNames = (d.dictionary(forKey: kNames) as? [String: String]) ?? [:]
        lastPage = (d.dictionary(forKey: kLastPages) as? [String: Int]) ?? [:]
        let loosePaths = d.stringArray(forKey: kLoose) ?? []
        looseEntries = loosePaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { PDFEntry(url: URL(fileURLWithPath: $0), root: "") }
        rescan()
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged),
            name: .PDFViewPageChanged, object: pdfView)
    }

    // MARK: - Folders

    func addFolders(_ urls: [URL]) {
        for u in urls where !rootFolders.contains(u.path) { rootFolders.append(u.path) }
        persistFolders()
        let firstNew = urls.first?.path
        rescan()
        if let p = firstNew, let f = folders.first(where: { $0.path == p }), let e = f.entries.first {
            select(e.id)
        }
    }

    func renameFolder(path: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { folderNames[path] = nil } else { folderNames[path] = trimmed }
        UserDefaults.standard.set(folderNames, forKey: kNames)
        if let i = folders.firstIndex(where: { $0.path == path }) {
            folders[i].name = trimmed.isEmpty ? (path as NSString).lastPathComponent : trimmed
        }
    }

    func removeFolder(path: String) {
        rootFolders.removeAll { $0 == path }
        folderNames[path] = nil
        persistFolders()
        UserDefaults.standard.set(folderNames, forKey: kNames)
        let lostSelection = orderedEntries.first { $0.id == selectedID }?.root == path
        rescan()
        if lostSelection { select(orderedEntries.first?.id) }
    }

    private func rescan() {
        let fm = FileManager.default
        var items: [FolderItem] = []
        for root in rootFolders {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            var found: [PDFEntry] = []
            if let it = fm.enumerator(at: rootURL,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
                for case let u as URL in it where u.pathExtension.lowercased() == "pdf" {
                    found.append(PDFEntry(url: u, root: root))
                }
            }
            found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let name = folderNames[root] ?? (root as NSString).lastPathComponent
            items.append(FolderItem(path: root, name: name, entries: found))
        }
        folders = items
        // a loose file that now lives inside an imported folder is no longer "loose"
        let inFolders = Set(folders.flatMap { $0.entries.map(\.id) })
        looseEntries.removeAll { inFolders.contains($0.id) }
        if selectedID == nil || !orderedEntries.contains(where: { $0.id == selectedID }) {
            select(orderedEntries.first?.id)
        }
    }

    // MARK: - Open external PDFs (Finder double-click / Open With)

    func openExternal(_ urls: [URL]) {
        var last: String?
        for u in urls where u.pathExtension.lowercased() == "pdf" {
            let id = u.path
            if !orderedEntries.contains(where: { $0.id == id }) {
                looseEntries.insert(PDFEntry(url: u, root: ""), at: 0)   // newest on top
            }
            last = id
        }
        persistLoose()
        if let id = last { focusZone = .sidebar; select(id) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func removeLoose(_ id: String) {
        looseEntries.removeAll { $0.id == id }
        persistLoose()
        if selectedID == id { select(orderedEntries.first?.id) }
    }

    private func persistLoose() {
        UserDefaults.standard.set(looseEntries.map { $0.url.path }, forKey: kLoose)
    }

    // MARK: - Default PDF handler

    func claimPDFDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: kClaimedPDF) else { return }
        claimPDFDefault()
        UserDefaults.standard.set(true, forKey: kClaimedPDF)
    }

    func claimPDFDefault() {
        let appURL = Bundle.main.bundleURL
        Task { try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .pdf) }
    }

    // MARK: - Selection

    private func entry(_ id: String) -> PDFEntry? { orderedEntries.first { $0.id == id } }
    private func folder(_ path: String) -> FolderItem? { folders.first { $0.path == path } }

    func select(_ id: PDFEntry.ID?) {
        if let id { sidebarTarget = .file(id) }
        guard selectedID != id else { return }
        selectedID = id
        loadSelected()
    }

    // Click handlers from the views.
    func clickFile(_ id: String) { focusZone = .sidebar; select(id) }
    func clickThumb(_ i: Int) { focusZone = .slides; goToPage(i) }
    func toggleFolder(_ path: String) {
        focusZone = .sidebar; sidebarTarget = .folder(path)
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }

    // MARK: - Arrow keys (focus-driven)

    func arrowUp()   { focusZone == .slides ? prevPage() : moveSidebar(-1) }
    func arrowDown() { focusZone == .slides ? nextPage() : moveSidebar(+1) }

    func arrowLeft() {
        if focusZone == .slides { focusZone = .sidebar; return }
        switch sidebarTarget {
        case .file(let id):                               // collapse parent, focus the folder
            if let root = entry(id)?.root, !root.isEmpty {  // loose files have no parent folder
                collapsed.insert(root); sidebarTarget = .folder(root)
            }
        case .folder(let p):
            if !collapsed.contains(p) { collapsed.insert(p) }
        case .none:
            sidebarTarget = visibleRows.first
        }
    }

    func arrowRight() {
        if focusZone == .slides { return }
        switch sidebarTarget {
        case .folder(let p):
            if collapsed.contains(p) { collapsed.remove(p) }          // expand
            else if let first = folder(p)?.entries.first { select(first.id) }  // enter first file
        case .file:
            focusZone = .slides                                       // hand off to slides
        case .none:
            sidebarTarget = visibleRows.first
        }
    }

    private func moveSidebar(_ delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let cur = sidebarTarget.flatMap { rows.firstIndex(of: $0) } ?? 0
        let next = max(0, min(rows.count - 1, cur + delta))
        let target = rows[next]
        sidebarTarget = target
        if case .file(let id) = target { select(id) }     // files load; folder rows only focus
    }

    private func loadSelected() {
        guard let id = selectedID, let entry = orderedEntries.first(where: { $0.id == id }) else {
            document = nil; pdfView.document = nil; pageCount = 0; currentPage = 0; return
        }
        loadToken += 1
        let token = loadToken
        isLoading = true
        let url = entry.url
        let restore = lastPage[id] ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            let doc = PDFDocument(url: url)
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.isLoading = false
                self.thumbs.reset()           // drop previous document's thumbnails
                self.document = doc
                self.pdfView.document = doc
                self.pdfView.autoScales = true   // new file resets to fit-window
                self.pageCount = doc?.pageCount ?? 0
                if let doc, restore < doc.pageCount, let p = doc.page(at: restore) {
                    self.pdfView.go(to: p); self.currentPage = restore
                } else { self.currentPage = 0 }
            }
        }
    }

    // MARK: - Page navigation

    func nextPage() { if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) } }
    func prevPage() { if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) } }

    // MARK: - Zoom

    func zoomIn()    { if pdfView.canZoomIn { pdfView.zoomIn(nil) } }
    func zoomOut()   { if pdfView.canZoomOut { pdfView.zoomOut(nil) } }
    func zoomFit()   { pdfView.autoScales = true }
    func zoomActual() { pdfView.autoScales = false; pdfView.scaleFactor = 1.0 }
    func goToPage(_ i: Int) {
        guard let p = document?.page(at: i) else { return }
        pdfView.go(to: p)
    }

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let cur = pdfView.currentPage else { return }
        let idx = doc.index(for: cur)
        currentPage = idx
        if let id = selectedID { lastPage[id] = idx; persistLastPagesThrottled() }
    }

    // MARK: - Persistence

    private func persistFolders() { UserDefaults.standard.set(rootFolders, forKey: kFolders) }

    private var persistWork: DispatchWorkItem?
    private func persistLastPagesThrottled() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [lastPage, kLastPages] in
            UserDefaults.standard.set(lastPage, forKey: kLastPages)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
