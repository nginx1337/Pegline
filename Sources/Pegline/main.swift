import AppKit

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    // Developer aid (debug builds only): renders the line with sample images to a PNG.
    PreviewRenderer.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
    exit(0)
}
#endif

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
