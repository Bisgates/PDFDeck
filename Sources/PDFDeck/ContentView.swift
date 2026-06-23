import SwiftUI
import PDFKit
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            HStack(spacing: 0) {
                ThumbnailList()
                    .frame(width: 192)
                Divider()
                pageColumn
            }
        }
        .navigationTitle("PDFDeck")
        .onAppear(perform: installKeyMonitor)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    }

    private var pageColumn: some View {
        ZStack {
            PDFViewWrapper(pdfView: model.pdfView)
            if model.selectedID == nil {
                ContentUnavailableView("No PDF selected",
                                       systemImage: "doc.richtext",
                                       description: Text("↑/↓ navigate · → into slides · ← collapse"))
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

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 123: model.arrowLeft();  return nil   // ←
            case 124: model.arrowRight(); return nil   // →
            case 126: model.arrowUp();    return nil   // ↑
            case 125: model.arrowDown();  return nil   // ↓
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
