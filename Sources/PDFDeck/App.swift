import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.claimPDFDefaultIfNeeded()   // one-time: become default PDF viewer
    }
    // Finder double-click / "Open With" / `open -a` delivers files here.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.openExternal(urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // Reopening (Dock click / `open`) focuses the existing window instead of spawning a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return false
    }
}

@main
struct PDFDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("PDFDeck", id: "main") {     // single-instance window (no duplicates/restored copies)
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { openFiles() }.keyboardShortcut("o")
                Button("Add Folder…") { addFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("Set as Default PDF Viewer") { model.claimPDFDefault() }
            }
            CommandGroup(after: .toolbar) {   // inject into the existing View menu
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)   // ⌘+ (also responds to ⌘=)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.zoomActual() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Zoom to Fit") { model.zoomFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }
    }

    private func openFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf]; p.prompt = "Open"
        if p.runModal() == .OK { model.openExternal(p.urls) }
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Add Folder"
        if p.runModal() == .OK { model.addFolders(p.urls) }
    }
}
