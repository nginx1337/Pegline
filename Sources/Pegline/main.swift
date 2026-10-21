import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    // Developer aid: renders the line with sample images to a PNG, without showing any window.
    PreviewRenderer.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
