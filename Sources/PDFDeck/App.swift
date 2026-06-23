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
}

@main
struct PDFDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
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
