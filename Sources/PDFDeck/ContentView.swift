import SwiftUI
import PDFKit
import AppKit

/// Resolves the hosting NSWindow so we can drive native fullscreen.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(v.window) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyMonitor: Any?
    @State private var fsObservers: [NSObjectProtocol] = []
    @State private var window: NSWindow?

    var body: some View {
        HStack(spacing: 0) {
            if !model.chromeHidden {
                Sidebar()
                    .frame(width: 250)
                    .background(.bar)
                Divider()
                ThumbnailList().frame(width: 192)
                Divider()
            }
            pageColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor { window = $0 })
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
        .onChange(of: model.fullscreen) { _, on in applyFullscreen(on) }
    }

    private var pageColumn: some View {
        ZStack {
            (model.chromeHidden ? Color.black : Color(nsColor: .textBackgroundColor))
                .ignoresSafeArea()
            PDFViewWrapper(pdfView: model.pdfView)
            if model.selectedID == nil && !model.chromeHidden {
                ContentUnavailableView("No PDF selected",
                                       systemImage: "doc.richtext",
                                       description: Text("1 single · 2 multiple · f panels · ⌘F fullscreen"))
            }
            if model.isLoading {
                ProgressView().controlSize(.large).padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack {
                Spacer()
                if model.pageCount > 0 {
                    Text("\(model.currentPage + 1) / \(model.pageCount)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Lifecycle

    private func setup() {
        installKeyMonitor()
        // keep `fullscreen` in sync if the user toggles native fullscreen another way
        let nc = NotificationCenter.default
        fsObservers = [
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.fullscreen = true }
            },
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.fullscreen = false }
            },
        ]
    }

    private func teardown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        fsObservers.forEach(NotificationCenter.default.removeObserver)
        fsObservers = []
    }

    private func applyFullscreen(_ on: Bool) {
        guard let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        win.collectionBehavior.insert(.fullScreenPrimary)
        if win.styleMask.contains(.fullScreen) != on { win.toggleFullScreen(nil) }
    }

    // MARK: Keyboard — all single-key (no modifiers)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // let text fields (e.g. the Rename dialog) receive typing/caret keys
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor { return event }
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 3:   model.toggleChrome();      return nil           // f  — hide sidebar + thumbnails
            case 18:  model.showSinglePage();    return nil           // 1  — single page
            case 19:  model.showMultiplePages(); return nil           // 2  — multiple pages (continuous)
            case 53:  return model.escape() ? nil : event             // esc — unwind fullscreen / panels
            case 123: model.arrowLeft();  return nil                  // ←
            case 124: model.arrowRight(); return nil                  // →
            case 126: model.arrowUp();    return nil                  // ↑
            case 125: model.arrowDown();  return nil                  // ↓
            case 24, 69:  model.zoomIn();  return nil                 // = / keypad+
            case 27, 78:  model.zoomOut(); return nil                 // - / keypad-
            case 29, 82:  model.zoomFit(); return nil                 // 0 / keypad0
            default: return event
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: String?
    @State private var renameText = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.looseEntries) { entry in fileRow(entry, topLevel: true) }
                    ForEach(model.folders) { folder in
                        folderRow(folder)
                        if !model.collapsed.contains(folder.path) {
                            ForEach(folder.entries) { entry in fileRow(entry, topLevel: false) }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.sidebarTarget) { _, t in scroll(proxy, t) }
            .onChange(of: model.focusZone) { _, _ in scroll(proxy, model.sidebarTarget) }
        }
        .safeAreaInset(edge: .bottom) {
            Button { addFolders() } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
        .overlay {
            if model.folders.isEmpty && model.looseEntries.isEmpty {
                ContentUnavailableView("No PDFs", systemImage: "folder.badge.plus",
                                       description: Text("Add a folder, or open a PDF."))
            }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { if let p = renaming { model.renameFolder(path: p, name: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Display name only; does not rename on disk.") }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ t: SidebarTarget?) {
        guard let t, model.focusZone == .sidebar else { return }
        withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(t.rowID, anchor: .center) }
    }

    // MARK: Rows

    private func folderRow(_ folder: FolderItem) -> some View {
        let t = SidebarTarget.folder(folder.path)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2).fontWeight(.semibold)
                .rotationEffect(.degrees(model.collapsed.contains(folder.path) ? 0 : 90))
                .frame(width: 12)
                .opacity(0.7)
            Image(systemName: "folder")
            Text(folder.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .foregroundStyle(fg(t))
        .background(bg(t), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleFolder(folder.path) }
        .contextMenu {
            Button("Rename…") { renameText = folder.name; renaming = folder.path }
            Button("Remove", role: .destructive) { model.removeFolder(path: folder.path) }
        }
        .id(t.rowID)
    }

    @ViewBuilder
    private func fileRow(_ entry: PDFEntry, topLevel: Bool) -> some View {
        let t = SidebarTarget.file(entry.id)
        HStack(spacing: 6) {
            Image(systemName: topLevel ? "doc.text.fill" : "doc.text")
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.leading, topLevel ? 8 : 28).padding(.trailing, 8)
        .foregroundStyle(fg(t))
        .background(bg(t), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.clickFile(entry.id) }
        .contextMenu {
            if topLevel { Button("Remove", role: .destructive) { model.removeLoose(entry.id) } }
        }
        .id(t.rowID)
    }

    // MARK: Highlight

    private func bg(_ t: SidebarTarget) -> Color {
        if model.focusZone == .sidebar && model.sidebarTarget == t { return .accentColor }
        if case .file(let id) = t, id == model.selectedID { return Color.secondary.opacity(0.22) }
        return .clear
    }
    private func fg(_ t: SidebarTarget) -> Color {
        (model.focusZone == .sidebar && model.sidebarTarget == t) ? .white : .primary
    }

    private func addFolders() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Add Folder"
        if p.runModal() == .OK { model.addFolders(p.urls) }
    }
}
