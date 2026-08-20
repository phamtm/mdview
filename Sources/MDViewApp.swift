import AppKit
import Combine
import SwiftUI

@main
struct MDViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var doc = DocumentModel.shared
    @StateObject private var workspace = WorkspaceModel.shared

    var body: some Scene {
        Window("MDView", id: "viewer") {
            ViewerView()
                .environmentObject(doc)
                .environmentObject(workspace)
        }
        .defaultSize(width: 1120, height: 940)
        // SwiftUI's own API for a transparent, text-free titlebar. Setting the
        // AppKit properties by hand loses: SwiftUI reapplies its titlebar config
        // after the scene is attached and puts the title text back.
        .windowStyle(.hiddenTitleBar)
        .commands { ViewerCommands(doc: doc, workspace: workspace) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["showFrontmatter": true])
        // Cormorant Garamond and Lora, so the chrome sets in the same faces as
        // the document. Must happen before any view is built.
        Typeface.register()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in DocumentModel.shared.open(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by tools/check-window-chrome.sh to confirm the titlebar treatment
        // survived SwiftUI's own window setup. It must not touch the real
        // document list, so it skips the restore below and exits.
        if ProcessInfo.processInfo.environment["MDVIEW_WINDOW_DUMP"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                print("WINDOW \(WindowStyler.shared.describe())")
                exit(0)
            }
            return
        }

        Task { @MainActor in
            // A path on the command line wins; otherwise reopen last session's file.
            let args = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if let path = args.first, DocumentModel.shared.url == nil {
                DocumentModel.shared.open(URL(fileURLWithPath: path))
                return
            }
            // Give a Finder open event a moment to arrive before restoring.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if DocumentModel.shared.url == nil, let last = DocumentModel.shared.lastDocument {
                DocumentModel.shared.open(last)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ViewerCommands: Commands {
    @ObservedObject var doc: DocumentModel
    @ObservedObject var workspace: WorkspaceModel
    @AppStorage("showFrontmatter") private var showFrontmatter = true
    @AppStorage("theme") private var theme = "system"
    @AppStorage("size") private var size = "regular"

    private func send(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { doc.openPanel() }
                .keyboardShortcut("o")

            Button("Add Folder to Sidebar…") { workspace.addFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent") {
                ForEach(doc.recents, id: \.path) { url in
                    Button(url.lastPathComponent) { doc.open(url) }
                }
                if !doc.recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { doc.clearRecents() }
                }
            }
            .disabled(doc.recents.isEmpty)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Reload") { send(.mdvReload) }
                .keyboardShortcut("r")
                .disabled(doc.url == nil)
            Button("Reveal in Finder") { doc.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(doc.url == nil)
            Button("Copy File Path") { send(.mdvCopyPath) }
                .disabled(doc.url == nil)
            Divider()
            Button("Print…") { send(.mdvPrint) }
                .keyboardShortcut("p")
                .disabled(doc.url == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { send(.mdvFind) }
                .keyboardShortcut("f")
                .disabled(doc.url == nil)
        }

        CommandMenu("View") {
            Button("Toggle Sidebar") { send(.mdvToggleSidebar) }
                .keyboardShortcut("b")
            Toggle(
                "Show All Files in Sidebar",
                isOn: Binding(
                    get: { workspace.showAllFiles },
                    set: { workspace.showAllFiles = $0 }))
            Button("Refresh Sidebar") { workspace.refresh() }
            // For `npm run watch`: reloads the page itself, picking up a rebuilt
            // bundle. Plain ⌘R only re-renders the document.
            Button("Reload Renderer") { send(.mdvReloadPage) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Zoom In") { send(.mdvZoomIn) }
                .keyboardShortcut("=")
            Button("Zoom Out") { send(.mdvZoomOut) }
                .keyboardShortcut("-")
            Button("Actual Size") { send(.mdvZoomReset) }
                .keyboardShortcut("0")
            Divider()
            Toggle(
                "Show Frontmatter",
                isOn: Binding(
                    get: { showFrontmatter },
                    set: {
                        showFrontmatter = $0; send(.mdvSettingsChanged)
                    }))
        }
    }
}
