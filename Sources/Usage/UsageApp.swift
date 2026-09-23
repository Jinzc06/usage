import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    let store = UsageStore()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var outsideClick: Any?
    private var previewWindow: NSWindow?
    private var didRender = false
    private let preview = ProcessInfo.processInfo.arguments.contains("--preview")

    func start() {
        let button = status.button
        button?.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button?.target = self
        button?.action = #selector(toggle)
        button?.title = store.statusTitle

        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentSize = NSSize(width: 588, height: 280)
        trackTitle()

        if preview {
            let preview = NSHostingController(rootView: PopoverView(store: store))
            let window = NSWindow(contentViewController: preview)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.title = "今天用量"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(srgbRed: 243 / 255, green: 239 / 255, blue: 230 / 255, alpha: 1)
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
        if popover.isShown { resizePopover() }
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
        guard let button = status.button else { return }
        if popover.isShown {
            closePopover()
            return
        }
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        store.refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func resizePopover() {
        guard let host = popover.contentViewController as? NSHostingController<PopoverView> else { return }
        let fitted = host.sizeThatFits(in: NSSize(width: 588, height: 1200))
        let height = max(fitted.height, store.showSettings ? 640 : 300)
        popover.contentSize = NSSize(width: 588, height: height)
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
