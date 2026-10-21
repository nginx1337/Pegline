import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    /// Opening Pegline again (from Finder or Spotlight) shows the line.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.line.show(reason: .pinned)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
