import AppKit
import SwiftUI

// Menu-bar (accessory) app. No Dock icon, no main window — just a status item
// that shows a popover with a slider per audio-playing app.

@available(macOS 14.4, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let mixer = Mixer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer.begin()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3",
                                   accessibilityDescription: "App Volume")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.contentViewController = NSHostingController(rootView: MenuView(mixer: mixer))
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            mixer.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.shutdown()
    }
}

@available(macOS 14.4, *)
@MainActor
func launch() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

if #available(macOS 14.4, *) {
    // Program entry runs on the main thread; assert that for the compiler.
    MainActor.assumeIsolated { launch() }
} else {
    fputs("AppVolumeMixer requires macOS 14.4 or newer (Core Audio process taps).\n", stderr)
    exit(1)
}
