import AppKit
import Observation
import SwiftUI

final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusController: NSObject {
    let store = UsageStore()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: UsagePanel
    private var outsideClick: Any?
    private var previewWindow: NSWindow?
    private var didRender = false
    private var anchorTop: CGFloat?
    private let preview = ProcessInfo.processInfo.arguments.contains("--preview")

    override init() {
        panel = UsagePanel(
            contentRect: NSRect(x: 0, y: 0, width: 588, height: 320),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        let host = NSHostingController(rootView: PopoverView(store: store))
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        host.sizingOptions = .preferredContentSize
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        host.view.layer?.isOpaque = false
        panel.contentViewController = host
    }

    func start() {
        let button = status.button
        button?.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button?.target = self
        button?.action = #selector(toggle)
        button?.title = store.statusTitle
        trackTitle()

        if preview {
            let preview = NSHostingController(rootView: PopoverView(store: store))
            let window = NSWindow(contentViewController: preview)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.title = "今天用量"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.setContentSize(NSSize(width: 588, height: 320))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }

    func trackTitle() {
        withObservationTracking {
            status.button?.title = store.statusTitle
            _ = store.showSettings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resizeIfNeeded()
                self?.renderIfNeeded()
                self?.trackTitle()
            }
        }
    }

    private func renderIfNeeded() {
        guard preview, store.loaded, !didRender else { return }
        didRender = true
        renderPreview()
    }

    private func resizeIfNeeded() {
        if panel.isVisible { resizePanel(keepingTop: true) }
        guard let window = previewWindow, let host = window.contentViewController else { return }
        host.view.layoutSubtreeIfNeeded()
        var size = host.view.fittingSize
        if size.width < 588 { size.width = 588 }
        if size.height > 1 {
            window.setContentSize(size)
        }
    }

    private func renderPreview() {
        writePreview(PopoverView(store: store), to: "/tmp/usage-preview.png")
        let wasOpen = store.showSettings
        store.showSettings = true
        writePreview(PopoverView(store: store), to: "/tmp/usage-settings.png")
        store.showSettings = wasOpen
    }

    private func writePreview(_ view: PopoverView, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let tiff = renderer.nsImage?.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        fputs("WROTE \(path)\n", stdout)
        fflush(stdout)
    }

    @objc private func toggle() {
        if panel.isVisible {
            closePanel()
            return
        }
        showPanel()
        store.refresh()
    }

    private func showPanel() {
        guard let button = status.button, let statusWindow = button.window else { return }
        resizePanel(keepingTop: false)
        let buttonOnScreen = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = panel.frame
        frame.origin.x = buttonOnScreen.midX - frame.width / 2
        frame.origin.y = buttonOnScreen.minY - frame.height - 8
        if let screen = statusWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            if frame.minY < visible.minY {
                frame.origin.y = buttonOnScreen.maxY + 8
            }
        }
        anchorTop = frame.maxY
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        status.button?.highlight(true)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.clickIsOnStatusButton() { return }
                self.closePanel()
            }
        }
    }

    private func closePanel() {
        store.returnToToday()
        panel.orderOut(nil)
        status.button?.highlight(false)
        anchorTop = nil
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
    }

    private func clickIsOnStatusButton() -> Bool {
        guard let button = status.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    private func resizePanel(keepingTop: Bool) {
        guard let host = panel.contentViewController as? NSHostingController<PopoverView> else { return }
        let fitted = host.sizeThatFits(in: NSSize(width: 588, height: 1400))
        let height = max(fitted.height, store.showSettings ? 760 : 340)
        var frame = panel.frame
        let top = anchorTop ?? frame.maxY
        frame.size = NSSize(width: 588, height: height)
        if keepingTop {
            frame.origin.y = top - height
        }
        panel.setFrame(frame, display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = StatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = ProcessInfo.processInfo.arguments.contains("--preview")
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        controller.start()
    }
}

@main
enum UsageMain {
    nonisolated(unsafe) private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        // app.run() has to sit outside assumeIsolated. Holding the main actor across the
        // run loop would block the store's refresh task forever.
        let delegate = MainActor.assumeIsolated { () -> AppDelegate in
            let delegate = AppDelegate()
            let preview = ProcessInfo.processInfo.arguments.contains("--preview")
            app.setActivationPolicy(preview ? .regular : .accessory)
            delegate.controller.start()
            return delegate
        }
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
