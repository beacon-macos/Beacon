import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: LauncherModel

    private var scheme: ColorScheme {
        model.resolvedColorScheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            settingsCard(title: "General") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow(
                        title: "Appearance",
                        detail: "Choose how Beacon looks, or follow the system setting."
                    ) {
                        Picker("Theme", selection: Binding(
                            get: { model.theme },
                            set: { newTheme in
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    model.updateTheme(newTheme)
                                }
                            }
                        )) {
                            ForEach(AppTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                        .accessibilityIdentifier("themePicker")
                    }

                    Divider().opacity(0.6)

                    settingRow(
                        title: "Open shortcut",
                        detail: "Show or hide Beacon from anywhere in macOS. Click the field, then press a key combination or double-tap a modifier."
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            ShortcutRecorder(shortcut: model.shortcut) { shortcut in
                                model.updateShortcut(shortcut)
                            }
                            .frame(width: 190, height: 34)
                            .accessibilityIdentifier("shortcutRecorder")

                            Button {
                                model.resetShortcut()
                            } label: {
                                Label("Reset to default", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.shortcut == .default)
                        }
                    }

                    if let error = model.shortcutRegistrationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.beaconErrorText(scheme))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.beaconErrorBackground(scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding([.horizontal, .bottom], 16)
                    }
                }
            }

            settingsCard(title: "Extensions") {
                settingRow(
                    title: "Manage extensions",
                    detail: "Browse, install, update, and remove extensions in the launcher."
                ) {
                    Button("Manage Extensions") {
                        model.presentExtensions()
                    }
                    .accessibilityIdentifier("manageExtensionsButton")
                }
            }

            settingsCard(title: "Keyboard") {
                VStack(spacing: 0) {
                    ForEach(Array(keyboardHints.enumerated()), id: \.offset) { index, hint in
                        if index > 0 {
                            Divider().opacity(0.6)
                        }
                        HStack {
                            Text(hint.action)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.beaconInk(scheme))
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(hint.keys, id: \.self) { key in
                                    KeyCap(key: key, scheme: scheme)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, alignment: .top)
        .background(Color.beaconCanvas(scheme))
        .background(SettingsWindowFocusView())
        .preferredColorScheme(model.theme.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: scheme)
        .accessibilityIdentifier("settingsView")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.beaconInk(scheme))
                .frame(width: 40, height: 40)
                .background(Color.beaconSelection(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 1) {
                Text("Beacon")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.beaconInk(scheme))
                Text("Launcher settings")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.beaconMuted(scheme))
            }

            Spacer()

            Text("Version \(appVersion)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.beaconMuted(scheme))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.beaconSelection(scheme), in: Capsule())
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var keyboardHints: [(action: String, keys: [String])] {
        [
            ("Open selection", ["↩"]),
            ("Move selection", ["↑", "↓"]),
            ("Add or remove favorite", ["⌘", "K"]),
            ("Rearrange favorites", ["⌥", "↑", "↓"]),
            ("Go back or close Beacon", ["esc"])
        ]
    }

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.beaconMuted(scheme))
                .padding(.leading, 4)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.beaconCard(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.beaconCardBorder(scheme))
                )
        }
    }

    private func settingRow<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.beaconInk(scheme))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.beaconMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .padding(16)
    }
}

private struct KeyCap: View {
    let key: String
    let scheme: ColorScheme

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.beaconInk(scheme))
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 4)
            .background(Color.beaconKeycapBackground(scheme), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.beaconKeycapBorder(scheme))
            )
    }
}

private struct SettingsWindowFocusView: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowFocusingView {
        SettingsWindowFocusingView()
    }

    func updateNSView(_ view: SettingsWindowFocusingView, context: Context) {}
}

private final class SettingsWindowFocusingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.tabbingMode = .disallowed

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut
    let onChange: (KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.needsDisplay = true
    }
}

private final class ShortcutRecorderView: NSView {
    var shortcut = KeyboardShortcut.default
    var onChange: ((KeyboardShortcut) -> Void)?
    private var isRecording = false
    private var doubleModifierDetectors = Dictionary(
        uniqueKeysWithValues: KeyboardShortcut.DoubleTapModifier.allCases.map {
            ($0, DoubleModifierPressDetector())
        }
    )

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        resetDoubleModifierDetectors()
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        resetDoubleModifierDetectors()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        let deviceFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        var detectedModifier: KeyboardShortcut.DoubleTapModifier?

        for modifier in KeyboardShortcut.DoubleTapModifier.allCases {
            var detector = doubleModifierDetectors[modifier] ?? DoubleModifierPressDetector()
            var otherModifiers = deviceFlags.intersection(relevantModifiers)
            otherModifiers.remove(modifier.eventFlag)
            if detector.flagsChanged(
                modifierIsPressed: deviceFlags.contains(modifier.eventFlag),
                hasOtherModifiers: !otherModifiers.isEmpty,
                timestamp: event.timestamp
            ) {
                detectedModifier = modifier
            }
            doubleModifierDetectors[modifier] = detector
        }
        guard let detectedModifier else { return }

        let newShortcut = KeyboardShortcut.doubleTap(detectedModifier)
        shortcut = newShortcut
        isRecording = false
        onChange?(newShortcut)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        resetDoubleModifierDetectors()
        let newShortcut = KeyboardShortcut(event: event)
        guard newShortcut.modifiers != 0 else {
            NSSound.beep()
            return
        }
        shortcut = newShortcut
        isRecording = false
        onChange?(newShortcut)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let fillColor: NSColor = isRecording
            ? NSColor.beaconDynamic(light: .white, dark: NSColor(white: 1, alpha: 0.18))
            : NSColor.beaconDynamic(
                light: NSColor(calibratedRed: 0.973, green: 0.969, blue: 0.953, alpha: 1),
                dark: NSColor(white: 1, alpha: 0.08)
            )
        fillColor.setFill()
        path.fill()
        let strokeColor: NSColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.75)
            : NSColor.beaconDynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.14))
        strokeColor.setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? "Type shortcut…" : shortcut.displayName
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style
        ]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: NSRect(x: 8, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height),
            withAttributes: attributes
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func resetDoubleModifierDetectors() {
        for modifier in KeyboardShortcut.DoubleTapModifier.allCases {
            var detector = doubleModifierDetectors[modifier] ?? DoubleModifierPressDetector()
            detector.reset()
            doubleModifierDetectors[modifier] = detector
        }
    }
}

extension Color {
    static func beaconErrorText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.95, green: 0.62, blue: 0.56)
            : Color(red: 0.57, green: 0.25, blue: 0.22)
    }

    static func beaconErrorBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.30, green: 0.16, blue: 0.14)
            : Color(red: 0.98, green: 0.92, blue: 0.91)
    }

    static func beaconCard(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.75)
    }

    static func beaconCardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
}

#Preview {
    SettingsView(model: LauncherModel.preview)
}
