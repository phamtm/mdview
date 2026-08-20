import Foundation

/// Actions the menu bar sends to the web view.
extension Notification.Name {
    static let mdvReload = Notification.Name("mdv.reload")
    static let mdvZoomIn = Notification.Name("mdv.zoomIn")
    static let mdvZoomOut = Notification.Name("mdv.zoomOut")
    static let mdvZoomReset = Notification.Name("mdv.zoomReset")
    static let mdvFind = Notification.Name("mdv.find")
    static let mdvPrint = Notification.Name("mdv.print")
    static let mdvCopyPath = Notification.Name("mdv.copyPath")
    static let mdvSettingsChanged = Notification.Name("mdv.settingsChanged")
    static let mdvToggleSidebar = Notification.Name("mdv.toggleSidebar")
    static let mdvReloadPage = Notification.Name("mdv.reloadPage")
    static let mdvOpenSettings = Notification.Name("mdv.openSettings")
    /// Asks the page to report what it actually rendered; see tools/check-theme.sh.
    static let mdvDumpPage = Notification.Name("mdv.dumpPage")
    static let mdvToggleFrontmatter = Notification.Name("mdv.toggleFrontmatter")
    static let mdvCopyDocument = Notification.Name("mdv.copyDocument")
    static let mdvToggleOutline = Notification.Name("mdv.toggleOutline")
    /// Carries the heading index as its object.
    static let mdvScrollToHeading = Notification.Name("mdv.scrollToHeading")
}
