#if DEBUG
import AppKit
import PeglineCore

/// Debug-only end-to-end check, run with PEGLINE_SELFTEST=1 (and PEGLINE_SELFTEST_DIR with sample images).
/// Exercises real actions inside the running app and prints PASS/FAIL lines, then quits.
enum SelfTest {
    static func run(_ model: AppModel) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ name: String) {
                print(ok ? "PASS \(name)" : "FAIL \(name)")
                if !ok { failures += 1 }
            }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            await wait(0.8)
            let line = model.line!
            let canvas = line.lineView.canvas

            // Many photos.
            if let dir = ProcessInfo.processInfo.environment["PEGLINE_SELFTEST_DIR"],
               let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for name in names.sorted() where name.hasSuffix(".png") {
                    let path = (dir as NSString).appendingPathComponent(name)
                    guard let px = ImageInfo.pixelSize(path: path), let probe = FileProbe.read(path: path) else { continue }
                    model.store.add(ShotRecord(path: path, bookmark: ShotStore.bookmark(for: URL(fileURLWithPath: path)),
                                               identity: probe.identity, addedAt: Date(), pixelWidth: px.width, pixelHeight: px.height))
                }
            }
            guard let first = model.store.shots.first else { print("FAIL no shots"); NSApp.terminate(nil); return }
            print("INFO shots on line: \(model.store.shots.count), screens: \(NSScreen.screens.count)")

            // Copy.
            check(model.actions.copy(first), "copy returns true")
            let pb = NSPasteboard.general
            let types = pb.types ?? []
            check(types.contains(.fileURL), "clipboard has file URL")
            check(types.contains(.png), "clipboard has PNG data")
            check(NSImage(pasteboard: pb) != nil, "clipboard image readable")
            check(pb.readObjects(forClasses: [NSURL.self])?.first as? URL == first.url, "clipboard URL is the file")

            // Drag payload: the same file URL a drag would carry.
            let writer = first.url as NSURL
            check(writer.writableTypes(for: pb).contains(.fileURL), "drag writer offers file URL")

            // Panel.
            line.show(reason: .pinned)
            await wait(0.9)
            let panel = line.panel
            check(panel.isVisible, "panel visible")
            check(!panel.canBecomeKey && !NSApp.isActive, "panel does not take focus")
            check(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary), "all Spaces + full screen")
            if let screen = panel.screen {
                print("INFO panel frame \(panel.frame) on screen \(screen.frame) visible \(screen.visibleFrame)")
                check(abs(panel.frame.maxY - screen.visibleFrame.maxY) < 1 || panel.frame.maxY <= screen.frame.maxY - screen.safeAreaInsets.top + 1, "panel sits under the menu bar")
                check(abs(panel.frame.midX - screen.frame.midX) < 1, "panel centred")
            }
            let visibleNodes = canvas.nodes.filter(\.isVisibleOnLine).count
            print("INFO visible photos \(visibleNodes) of \(canvas.nodes.count), visibleCount \(canvas.visibleCount)")
            check(visibleNodes <= canvas.visibleCount + 1, "visible photos limited")
            let widths = Set(canvas.nodes.filter(\.isVisibleOnLine).map { Int($0.cardSize.width) })
            check(widths.allSatisfy { $0 >= 60 }, "photos do not shrink")

            // Pointer pass-through.
            check(panel.ignoresMouseEvents, "clicks pass through away from photos")
            if let node = canvas.nodes.first(where: \.isVisibleOnLine) {
                let center = panel.convertPoint(toScreen: line.lineView.convert(NSPoint(x: node.cardFrame.midX, y: node.cardFrame.midY), to: nil))
                line.updatePointer(center)
                check(!panel.ignoresMouseEvents, "photo under pointer receives clicks")
                check(node.isHovered, "photo shows hover")
                line.updatePointer(NSPoint(x: center.x, y: center.y - 400))
                check(panel.ignoresMouseEvents, "pass-through again after leaving")
            }

            // Scrolling through a long line.
            if canvas.maxScrollOffset > 0 {
                let before = canvas.scrollOffset
                canvas.page(1)
                check(canvas.scrollOffset > before, "page right scrolls")
                print("INFO hidden left/right \(canvas.hiddenCounts)")
                canvas.page(-1)
                check(canvas.scrollOffset == 0, "page left back to start")
            }

            // Markup availability.
            print("INFO markup service available: \(MarkupPresenter.isAvailable)")

            // Unpin keeps the file.
            if let last = model.store.shots.last {
                model.actions.unpin(last)
                check(FileManager.default.fileExists(atPath: last.path), "unpin keeps the file")
                check(model.store.record(id: last.id) == nil, "unpin removes from line")
            }

            // Mouse handling with synthesized events.
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: line.lineView.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            }
            if let node = canvas.nodes.first(where: \.isVisibleOnLine) {
                let p = NSPoint(x: node.cardFrame.midX, y: node.cardFrame.midY)
                pb.clearContents()
                pb.setString("keep", forType: .string)
                canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: 1))
                canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: 1))
                check(pb.string(forType: .string) == "keep", "single click waits before copying")
                canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: 2))
                canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: -500, y: -500), clicks: 2))
                await wait(NSEvent.doubleClickInterval + 0.3)
                check(pb.string(forType: .string) == "keep", "double-click leaves the clipboard alone")
                canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: 1))
                canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: 1))
                await wait(NSEvent.doubleClickInterval + 0.3)
                check(pb.types?.contains(.fileURL) == true, "single click copies after the pause")
                check(line.interactions == 0, "clicks leave no interaction open")

                // The pressed photo disappears before the button is released.
                canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: 1))
                check(line.interactions == 1, "press starts an interaction")
                model.store.remove(id: node.id, reason: .unpinned)
                canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: 1))
                check(line.interactions == 0, "press ends even if the photo vanished")
                check(model.store.collection.wasDismissed(path: node.record.path, identity: node.record.identity),
                      "unpinned photo remembered as dismissed")
                pb.clearContents()
                pb.setString("Pegline self-test", forType: .string)
            }

            // System settings: Pegline never undoes a change the user made in ⇧⌘5 meanwhile.
            do {
                let suite = "app.pegline.selftest"
                let scratch = UserDefaults(suiteName: suite)!
                scratch.removePersistentDomain(forName: suite)
                let domain = "app.pegline.selftest.screencapture" as CFString
                let key = "show-thumbnail" as CFString
                func value() -> Bool? {
                    CFPreferencesAppSynchronize(domain)
                    return CFPreferencesCopyAppValue(key, domain) as? Bool
                }
                func userSets(_ v: Bool?) {
                    CFPreferencesSetAppValue(key, v as CFPropertyList?, domain)
                    CFPreferencesAppSynchronize(domain)
                }
                userSets(nil)
                let settings = ScreenshotSystemSettings(domain: domain, defaults: scratch)
                check(settings.set("show-thumbnail", false as CFPropertyList) && value() == false, "managed value applied")
                settings.restore("show-thumbnail")
                check(value() == nil, "original restored when untouched")
                _ = settings.set("show-thumbnail", false as CFPropertyList)
                userSets(true)
                settings.restore("show-thumbnail")
                check(value() == true, "user's later choice kept on restore")
                _ = settings.set("show-thumbnail", false as CFPropertyList)
                userSets(true)
                check(!settings.set("show-thumbnail", false as CFPropertyList) && value() == true, "re-apply yields to the user's change")
                check(!settings.hasChanges, "nothing left to restore after yielding")
                userSets(nil)
                scratch.removePersistentDomain(forName: suite)
            }

            // The saved line is private to this user.
            model.store.saveNow()
            let support = ProcessInfo.processInfo.environment["PEGLINE_STORE_DIR"].map { URL(fileURLWithPath: $0) }
            if let archive = support?.appendingPathComponent("line.json") {
                let mode = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int) ?? 0
                check(mode == 0o600, "line.json readable by this user only")
            }

            // Hide releases everything.
            line.hide()
            await wait(0.8)
            check(!panel.isVisible, "panel ordered out after hide")
            check(canvas.nodes.allSatisfy { ($0.hanger.animationKeys() ?? []).isEmpty }, "no animations left running")
            check(model.store.shots.count > 0, "hiding keeps photos")

            // Skipped beside a real instance: it shares the same settings.
            if ProcessInfo.processInfo.environment["PEGLINE_STORE_DIR"] == nil {
                // Consent-managed system setting and its restore.
                let before = SystemScreenshotPrefs.value("show-thumbnail")
                model.prefs.manageFloatingThumbnail = true
                await wait(0.3)
                check(SystemScreenshotPrefs.showsFloatingThumbnail == false, "floating thumbnail turned off on request")
                model.systemSettings.restoreAll()
                let after = SystemScreenshotPrefs.value("show-thumbnail")
                check((before == nil && after == nil) || (before as? Bool) == (after as? Bool), "original value restored")
                model.prefs.manageFloatingThumbnail = false
            }

            // Clipboard: a screenshot copied with ⌃⇧⌘4 is just image data on the clipboard.
            if ProcessInfo.processInfo.environment["PEGLINE_SELFTEST_CLIPBOARD"] != nil {
                let savedMode = model.prefs.clipboardMode
                defer { model.prefs.clipboardMode = savedMode }
                model.prefs.clipboardMode = .screenshots
                let png = ImageInfo.pngData(path: first.path)!
                let countBefore = model.store.shots.count
                let shot = NSPasteboardItem()
                shot.setData(png, forType: .png)
                pb.clearContents()
                pb.writeObjects([shot])
                await wait(1.2)
                let hung = model.store.shots.first
                check(hung?.origin == "clipboard", "clipboard screenshot hung on the line")
                if let hung {
                    check(hung.path.hasPrefix(ClipboardImporter.folder.path), "saved into Pictures/Pegline")
                    check(ScreenshotClassifier.hasScreenCaptureAttribute(atPath: hung.path), "marked as a screenshot")
                    print("INFO saved \(hung.path)")
                }
                check(model.store.shots.count == countBefore + 1, "exactly one photo added")

                if let hung {
                    let mode = (try? FileManager.default.attributesOfItem(atPath: hung.path)[.posixPermissions] as? Int) ?? 0
                    let folderMode = (try? FileManager.default.attributesOfItem(atPath: ClipboardImporter.folder.path)[.posixPermissions] as? Int) ?? 0
                    check(mode == 0o600 && folderMode == 0o700, "clipboard images readable by this user only")
                }

                // A password manager's concealed item is never read or saved.
                let secret = NSPasteboardItem()
                secret.setData(ImageInfo.pngData(path: model.store.shots.last!.path)!, forType: .png)
                secret.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                let beforeSecret = model.store.shots.count
                pb.clearContents()
                pb.writeObjects([secret])
                await wait(1.0)
                check(model.store.shots.count == beforeSecret, "concealed clipboard item ignored")

                // The same picture copied again does not hang twice.
                pb.clearContents()
                pb.writeObjects([{ let i = NSPasteboardItem(); i.setData(png, forType: .png); return i }()])
                await wait(1.0)
                check(model.store.shots.count == countBefore + 1, "same image not added twice")

                // An image copied from a web page is not a screenshot.
                let web = NSPasteboardItem()
                web.setData(ImageInfo.pngData(path: model.store.shots.last!.path)!, forType: .png)
                web.setString("<img src=x>", forType: .html)
                pb.clearContents()
                pb.writeObjects([web])
                await wait(1.0)
                check(model.store.shots.count == countBefore + 1, "web image ignored in screenshots mode")

                // Telegram-style copy: a file in another app's private container we cannot read, plus TIFF data.
                model.prefs.clipboardMode = .allImages
                func writeFileCopy(path: String, tiffFrom imagePath: String) {
                    let fileItem = NSPasteboardItem()
                    fileItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                    let imageItem = NSPasteboardItem()
                    imageItem.setData(NSImage(contentsOfFile: imagePath)!.tiffRepresentation!, forType: .tiff)
                    pb.clearContents()
                    pb.writeObjects([fileItem, imageItem])
                }
                let samplePath = model.store.shots.last!.path
                var count = model.store.shots.count
                writeFileCopy(path: "/Users/nobody/Library/Containers/ru.keepcoder.Telegram/Data/tmp/photo.jpg", tiffFrom: samplePath)
                await wait(1.2)
                check(model.store.shots.count == count + 1, "Telegram-style image (unreadable file + TIFF) hung")
                check(model.store.shots.first?.origin == "clipboard", "Telegram-style image saved as a copy")

                // Finder copy of a folder: the TIFF is only the folder icon.
                count = model.store.shots.count
                writeFileCopy(path: NSHomeDirectory(), tiffFrom: samplePath)
                await wait(1.2)
                check(model.store.shots.count == count, "copied folder icon ignored")

                // Image file in a temporary place: hang a copy, since the original may vanish.
                count = model.store.shots.count
                let temp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pegline-selftest.jpg")
                let jpeg = NSBitmapImageRep(data: NSImage(contentsOfFile: samplePath)!.tiffRepresentation!)!
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
                try? jpeg.write(to: URL(fileURLWithPath: temp))
                writeFileCopy(path: temp, tiffFrom: samplePath)
                await wait(1.2)
                check(model.store.shots.count == count + 1, "temporary image file copied onto the line")
                check(model.store.shots.first?.path.hasSuffix(".jpg") == true, "JPEG kept as JPEG")
                try? FileManager.default.removeItem(atPath: temp)
                model.prefs.clipboardMode = .screenshots

                // Pegline's own copy is never re-added.
                model.prefs.clipboardMode = .allImages
                count = model.store.shots.count
                model.actions.copy(model.store.shots.last!)
                await wait(1.0)
                check(model.store.shots.count == count, "own copy not re-added")
                // Data that only claims to be PNG is not written to disk.
                let beforeJunk = model.store.shots.count
                let junk = NSPasteboardItem()
                junk.setData(Data("not an image".utf8), forType: .png)
                pb.clearContents()
                pb.writeObjects([junk])
                await wait(1.0)
                check(model.store.shots.count == beforeJunk, "fake image data rejected")

                // Leave plain text behind so other running copies of Pegline have nothing to pick up.
                pb.clearContents()
                pb.setString("Pegline self-test", forType: .string)
            }

            if ProcessInfo.processInfo.environment["PEGLINE_SELFTEST_OPEN"] != nil {
                model.actions.openInPreview(first)
                await wait(1.5)
                check(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").count > 0, "Preview opened")
            }
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED \(failures)")
            if ProcessInfo.processInfo.environment["PEGLINE_SELFTEST_STAY"] == nil { NSApp.terminate(nil) }
        }
    }
}
#endif
