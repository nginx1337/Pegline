import SwiftUI

enum OnboardingWindow {
    static func make(model: AppModel, onFinish: @escaping () -> Void) -> NSWindow {
        let view = OnboardingView(model: model, prefs: model.prefs, state: OnboardingState(), onFinish: onFinish)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Знакомство с Pegline"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 620, height: 660))
        window.isReleasedWhenClosed = false
        return window
    }
}

@Observable
final class OnboardingState {
    var step = 0
    var shotsAtTestStart = 0
}

struct OnboardingView: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let state: OnboardingState
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ClotheslineIllustration(highlightNewest: state.step == 2 && testSucceeded)
                .frame(height: 170)
                .padding(.top, 34)
                .accessibilityHidden(true)

            Group {
                switch state.step {
                case 0: welcome
                case 1: integration
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            .padding(.top, 14)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            footer
        }
        .frame(width: 620, height: 660)
        .background(.background)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: state.step)
    }

    private var testSucceeded: Bool { model.shotsAddedThisSession > state.shotsAtTestStart }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Text("Скриншоты — на верёвке")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Каждый новый снимок экрана повиснет у верхнего края, как свежая фотография на прищепке. Оттуда его легко скопировать, открыть или перетащить куда нужно — без поиска в Finder.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 22) {
                gesture("cursorarrow.click", "Клик", "копирует")
                gesture("cursorarrow.click.2", "Двойной клик", "«Просмотр»")
                gesture("hand.tap", "Удержание", "«Разметка»")
                gesture("hand.draw", "Перетащите", "в любую программу")
            }
            .padding(.top, 10)
        }
    }

    private func gesture(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 26)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 112)
    }

    private var integration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Как Pegline находит снимки")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
            row("folder", "Следит за папкой снимков",
                "Сейчас это \(model.folderPath). Если вы смените её в ⇧⌘5 → Параметры, Pegline заметит это сам.") {
                if model.accessProblem == nil {
                    Label("Доступ есть", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                } else {
                    Button("Разрешить доступ") { model.requestFolderAccess() }
                }
            }
            row("bolt", "Снимок может появляться сразу",
                model.floatingThumbnailShown && !prefs.manageFloatingThumbnail
                    ? "Сейчас macOS около 5 секунд показывает миниатюру в углу и только потом сохраняет файл."
                    : "Плавающая миниатюра выключена — файл сохраняется мгновенно.") {
                if model.floatingThumbnailShown || prefs.manageFloatingThumbnail {
                    Toggle("", isOn: Binding(
                        get: { prefs.manageFloatingThumbnail },
                        set: { model.setFloatingThumbnailManaged($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Сохранять снимок сразу")
                }
            }
            row("doc.on.clipboard", "Снимки в буфер обмена тоже",
                "⌃⇧⌘4 сохраняет снимок только в буфер — Pegline сохранит его в «Изображения/Pegline» и повесит на верёвку. macOS один раз спросит разрешение на вставку.") {
                EmptyView()
            }
            row("hand.raised", "Ничего не меняется без вашего согласия",
                "Системные параметры Pegline трогает только по вашему подтверждению, запоминает исходные значения и возвращает их при выходе.") {
                EmptyView()
            }
            row("lock.shield", "Всё остаётся на Mac",
                "Никакой сети, аналитики и учётных записей. Pegline хранит только ссылки на файлы.") {
                EmptyView()
            }
        }
    }

    private func row<Accessory: View>(
        _ symbol: String, _ title: String, _ detail: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }

    private var tryIt: some View {
        VStack(spacing: 16) {
            Text(testSucceeded ? "Получилось!" : "Попробуйте прямо сейчас")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
            HStack(spacing: 6) {
                KeyCap("⇧")
                KeyCap("⌘")
                KeyCap("4")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shift, Command, 4")
            Text(testSucceeded
                 ? "Снимок уже висит у верхнего края экрана. Щёлкните его, чтобы скопировать, или перетащите в другое окно."
                 : "Выделите любую область экрана — через мгновение снимок появится на верёвке у верхнего края.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if testSucceeded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Снимок обнаружен")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Ждём снимок…")
                }
            }
            .font(.callout)
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                tip("rectangle.topthird.inset.filled", "Чтобы снова увидеть верёвку, задержите курсор у верхнего края посередине экрана.")
                tip("keyboard", "\(prefs.hotKey?.displayString ?? "Сочетание клавиш") — показать или скрыть верёвку.")
                tip("menubar.rectangle", "Настройки и недавние снимки — в значке Pegline в строке меню.")
            }
            .padding(.top, 8)
        }
        .onAppear { state.shotsAtTestStart = model.shotsAddedThisSession }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == state.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == state.step ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Шаг \(state.step + 1) из 3")
            Spacer()
            if state.step > 0 {
                Button("Назад") { state.step -= 1 }
                    .controlSize(.large)
            }
            Button(state.step == 2 ? "Готово" : "Далее") {
                if state.step == 2 { onFinish() } else { state.step += 1 }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .frame(width: 44, height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// A small live drawing of the line: three photos gently swaying.
/// Uses the same pin colours and proportions as the real one.
struct ClotheslineIllustration: View {
    var highlightNewest: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
        let palette = LinePalette.make(dark: scheme == .dark)
        let left = CGPoint(x: 40, y: 22), right = CGPoint(x: size.width - 40, y: 22)
        let sag: CGFloat = 22
        func ropeY(_ x: CGFloat) -> CGFloat {
            let t = (x - left.x) / (right.x - left.x)
            return left.y + sag * 4 * t * (1 - t)
        }
        var rope = Path()
        rope.move(to: left)
        rope.addQuadCurve(to: right, control: CGPoint(x: size.width / 2, y: left.y + sag * 2))
        ctx.stroke(rope, with: .color(Color(cgColor: palette.rope)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        ctx.stroke(rope, with: .color(Color(cgColor: palette.ropeTwist)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [1.3, 2.4]))
        for hook in [left, right] {
            ctx.fill(Path(ellipseIn: CGRect(x: hook.x - 3, y: hook.y - 3, width: 6, height: 6)), with: .color(Color(cgColor: palette.hook)))
        }

        let screens: [(Color, Color)] = [
            (Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.86, green: 0.89, blue: 0.93)),
            (Color(red: 0.93, green: 0.90, blue: 0.84), Color(red: 0.55, green: 0.62, blue: 0.52)),
            (Color(red: 0.20, green: 0.22, blue: 0.26), Color(red: 0.85, green: 0.66, blue: 0.48))
        ]
        let xs = [size.width / 2 - 150, size.width / 2, size.width / 2 + 150]
        for (index, x) in xs.enumerated() {
            let w: CGFloat = 124, h: CGFloat = 84
            let pivot = CGPoint(x: x, y: ropeY(x))
            let phase = Double(index) * 1.7
            var angle = reduceMotion ? 0 : 0.03 * sin(time * 2 * .pi / 3.2 + phase)
            if index == 0, highlightNewest, !reduceMotion { angle += 0.05 * sin(time * 5) * exp(-fmod(time, 4)) }
            var layer = ctx
            layer.translateBy(x: pivot.x, y: pivot.y)
            layer.rotate(by: .radians(angle))
            let card = CGRect(x: -w / 2, y: 4, width: w, height: h)
            layer.drawLayer { shadowed in
                shadowed.addFilter(.shadow(color: .black.opacity(Double(palette.cardShadowOpacity)), radius: 5, x: 0, y: 3))
                shadowed.fill(Path(roundedRect: card, cornerRadius: 2.5), with: .color(Color(cgColor: palette.paper)))
            }
            let inner = card.insetBy(dx: 3, dy: 3)
            layer.fill(Path(roundedRect: inner, cornerRadius: 1.2), with: .color(screens[index].0))
            // A tiny "window" inside each photo.
            let window = CGRect(x: inner.minX + 14, y: inner.minY + 12, width: inner.width - 28, height: inner.height - 22)
            layer.fill(Path(roundedRect: window, cornerRadius: 4), with: .color(screens[index].1))
            for dot in 0..<3 {
                let r = CGRect(x: window.minX + 6 + CGFloat(dot) * 7, y: window.minY + 5, width: 4, height: 4)
                layer.fill(Path(ellipseIn: r), with: .color(.black.opacity(0.18)))
            }
            let pin = CGRect(x: -3.25, y: -8, width: 6.5, height: 21)
            layer.fill(Path(roundedRect: pin, cornerRadius: 2.4), with: .color(Color(cgColor: palette.pins[index])))
            layer.fill(Path(roundedRect: CGRect(x: -4.5, y: -1.6, width: 9, height: 3.2), cornerRadius: 1.6),
                       with: .color(Color(cgColor: palette.spring)))
        }
    }
}
