import SwiftUI
import Carbon.HIToolbox
import PeglineCore

enum SettingsWindow {
    static func make(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(model: model, prefs: model.prefs, recorder: HotKeyRecorderState()))
        let window = NSWindow(contentViewController: controller)
        window.title = "Настройки Pegline"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 540, height: 680))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PeglineSettings")
        return window
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let recorder: HotKeyRecorderState

    var body: some View {
        Form {
            Section("Верёвка") {
                Picker("Размер фотографий", selection: $prefs.thumbnailSize) {
                    ForEach(ThumbnailSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Видно одновременно", selection: $prefs.visibleCount) {
                    ForEach(Preferences.visibleCountChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Анимации", selection: $prefs.motion) {
                    ForEach(MotionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                     ? "В системе включено «Уменьшение движения», поэтому фотографии только плавно появляются."
                     : prefs.motion.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("Помнить до \(prefs.lineCapacity) снимков", value: $prefs.lineCapacity, in: 10...200, step: 10)
            }

            Section {
                Toggle("Показывать при новом снимке экрана", isOn: $prefs.showOnNewShot)
                Toggle("Прятать автоматически", isOn: $prefs.autoHide)
                if prefs.autoHide {
                    LabeledContent("Через \(Int(prefs.autoHideDelay)) с") {
                        Slider(value: $prefs.autoHideDelay, in: 3...20, step: 1).frame(width: 220)
                    }
                }
                Toggle(isOn: $prefs.revealOnEdge) {
                    Text("Раскрывать у верхнего края экрана")
                    Text("Задержите курсор у самого верха посередине экрана.")
                }
                Picker("Задержка раскрытия", selection: $prefs.revealDelay) {
                    ForEach(RevealDelay.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.revealOnEdge)
                LabeledContent("Показать или скрыть") {
                    HotKeyRecorder(combo: $prefs.hotKey, state: recorder)
                }
                if let problem = model.hotKeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Когда показывать")
            }

            Section {
                LabeledContent("Папка") {
                    HStack {
                        Text(model.folderPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Показать") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.detector.folder])
                        }
                    }
                }
                Picker("Следить за папкой", selection: Binding(
                    get: { prefs.folderMode },
                    set: { mode in
                        if mode == .custom { model.chooseCustomFolder() } else { prefs.folderMode = .system }
                    })) {
                    Text("Куда сохраняет система").tag(FolderMode.system)
                    Text("Своя папка…").tag(FolderMode.custom)
                }
                Picker("Добавлять", selection: $prefs.capturePolicy) {
                    Text("Только снимки экрана").tag(CapturePolicy.screenshotsOnly)
                    Text("Все новые изображения").tag(CapturePolicy.allImages)
                }
                Toggle(isOn: $prefs.useSpotlight) {
                    Text("Находить снимки и в других папках")
                    Text("С помощью Spotlight — например, если вы сменили папку в ⇧⌘5.")
                }
                if let problem = model.accessProblem {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(problem, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                        HStack {
                            Button("Запросить доступ") { model.requestFolderAccess() }
                            Button("Открыть настройки конфиденциальности") { PrivacyLinks.openFilesAndFolders() }
                        }
                    }
                }
                Picker("Из буфера обмена", selection: $prefs.clipboardMode) {
                    ForEach([ClipboardMode.screenshots, .allImages, .off], id: \.self) {
                        Text(Preferences.title(for: $0)).tag($0)
                    }
                }
                Text(prefs.clipboardMode == .off
                     ? "Снимки, сделанные сразу в буфер (⌃⇧⌘4), на верёвку не попадут."
                     : "Скопированные картинки сохраняются в «Изображения/Pegline» и вешаются на верёвку. При первом снимке macOS спросит, можно ли Pegline читать буфер обмена.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.clipboardDenied {
                    HStack {
                        Label("macOS запрещает Pegline читать буфер обмена.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Открыть настройки") { PrivacyLinks.openPasteboard() }
                    }
                }
                if !model.savesToFile, prefs.clipboardMode == .off {
                    Label("Системный инструмент сохраняет снимки не в файл. Выберите папку в ⇧⌘5 → Параметры, чтобы они появлялись на верёвке.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Снимки экрана")
            }

            Section {
                Text("Эти параметры меняются только с вашего согласия и только пока Pegline открыт. Исходные значения сохранены и возвращаются при выходе.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { prefs.manageFloatingThumbnail },
                    set: { model.setFloatingThumbnailManaged($0) })) {
                    Text("Сохранять снимок сразу")
                    Text("Отключает плавающую миниатюру: без неё macOS сохраняет файл мгновенно, а не через ~5 секунд.")
                }
                Toggle(isOn: Binding(
                    get: { prefs.manageLocation },
                    set: { model.setLocationManaged($0) })) {
                    Text("Сохранять снимки в отдельную папку")
                    if prefs.manageLocation, let path = prefs.managedLocationPath {
                        Text(ShotFormatting.abbreviatedPath(URL(fileURLWithPath: path)))
                    } else {
                        Text("Например, чтобы не загромождать рабочий стол.")
                    }
                }
                HStack {
                    Spacer()
                    Button("Вернуть исходные настройки") { model.restoreSystemSettingsNow() }
                        .disabled(!model.systemSettingsChanged)
                }
            } header: {
                Text("Системный инструмент «Снимок экрана»")
            }

            Section("Общие") {
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItem($0) }))
                if let message = model.loginItemMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Label("Снимки не покидают этот Mac: Pegline не использует сеть, аналитику и учётные записи.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 560)
    }
}

/// Records a global shortcut. The current one is released while recording so it can be re-entered.
/// State lives in a class because the command line toolchain has no SwiftUI macro plugin for @State.
@Observable
final class HotKeyRecorderState {
    var recording = false
    @ObservationIgnored var monitor: Any?
}

struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo?
    let state: HotKeyRecorderState
    private var recording: Bool { state.recording }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Нажмите сочетание…" : (combo?.displayString ?? "Не задано"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(recording ? "Запись сочетания клавиш" : "Сочетание клавиш: \(combo?.displayString ?? "не задано")")
            if combo != nil, !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Убрать сочетание клавиш")
            }
            if combo != .defaultCombo, !recording {
                Button("По умолчанию") { combo = .defaultCombo }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        state.recording = true
        HotKeyCenter.shared.suspend()
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if let new = HotKeyCombo(event: event) {
                combo = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
        state.monitor = nil
        if state.recording {
            state.recording = false
            HotKeyCenter.shared.resume()
        }
    }
}
