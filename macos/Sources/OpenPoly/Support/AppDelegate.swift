import AppKit
import OpenPolyCore
import SwiftUI
import ServiceManagement

/// AppKit owns the two desktop surfaces; SwiftUI owns their content and state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let module: any DeviceModule
    private let display: DisplayService
    private var isTerminating = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var controlsWindow: NSWindow?

    override init() {
        let display = DisplayService()
        self.display = display
        self.module = P21Module(display: display)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "OpenPoly controls")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.toolTip = "OpenPoly · \(module.displayName)"
        statusItem = item
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: module.makeQuickControls(openControls: { [weak self] in self?.openControls() })
        )
        if CommandLine.arguments.contains("--open-controls") || CommandLine.arguments.contains("--open-display") { openControls() }
        if CommandLine.arguments.contains("--enable-login") { try? SMAppService.mainApp.register() }
        if CommandLine.arguments.contains("--start-display") { display.start() }
        else { display.startIfEnabled() }
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quick = NSMenuItem(title: "Quick controls", action: #selector(togglePanel), keyEquivalent: "")
        quick.target = self
        appMenu.addItem(quick)
        let open = NSMenuItem(title: "Open controls", action: #selector(showControls), keyEquivalent: "o")
        open.target = self
        appMenu.addItem(open)
        let refresh = NSMenuItem(title: "Refresh device", action: #selector(refreshDevice), keyEquivalent: "r")
        refresh.target = self
        appMenu.addItem(refresh)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenPoly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    @objc private func showControls() { openControls() }
    @objc private func refreshDevice() { Task { await module.refresh() } }

    func openControls() {
        popover.performClose(nil)
        if controlsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.delegate = self
            window.title = "OpenPoly"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: module.makeControls())
            window.minSize = NSSize(width: 960, height: 600)
            window.center()
            window.setFrameAutosaveName("OpenPolyControlsCompact")
            controlsWindow = window
        }
        controlsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlsWindow else { return }
        window.contentViewController = nil
        controlsWindow = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openControls()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard display.isActive else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { await display.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
