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

    // The keyboard shortcuts. The page owns scrolling and the outline, so these
    // ask it rather than computing anything; each carries ±1 as its object.
    /// A half page down (+1) or up (-1).
    static let mdvScrollHalfPage = Notification.Name("mdv.scrollHalfPage")
    /// The end of the document (+1) or its start (-1).
    static let mdvScrollToEdge = Notification.Name("mdv.scrollToEdge")
    /// The next heading (+1) or the previous one (-1).
    static let mdvStepHeading = Notification.Name("mdv.stepHeading")
    /// Escape from the chrome: closes the page's find bar if it is open.
    static let mdvDismissFind = Notification.Name("mdv.dismissFind")
    /// Opens the shortcuts overlay; handled by `ViewerView`.
    static let mdvShowShortcuts = Notification.Name("mdv.showShortcuts")
    /// Opens Quick Open; handled by `ViewerView`.
    static let mdvQuickOpen = Notification.Name("mdv.quickOpen")
    /// Carries a Bool: an input inside the page took or lost focus.
    static let mdvPageInputFocus = Notification.Name("mdv.pageInputFocus")
}
