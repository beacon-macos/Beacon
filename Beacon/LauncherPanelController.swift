import AppKit
import SwiftUI

extension Notification.Name {
    static let beaconDidShow = Notification.Name("Beacon.didShow")
}

@MainActor
final class LauncherPanelController: NSWindowController, NSWindowDelegate {
    private let model: LauncherModel

    var onHide: (() -> Void)?

    init(model: LauncherModel) {
        self.model = model

        let panel = BeaconPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        let contentView = NSHostingView(rootView: ContentView(model: model))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 14
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        panel.contentView = contentView
        panel.setFrameAutosaveName("BeaconLauncherPanel")

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel = window else { return }
        model.prepareForPresentation()
        panel.appearance = model.theme.appearance

        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .beaconDidShow, object: nil)
    }

    func hide() {
        window?.orderOut(nil)
        onHide?()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

private final class BeaconPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
