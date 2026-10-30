import AppKit
import SwiftUI
import ClipVaultCore
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = ClipboardController(storage: EncryptedVaultStore(url: EncryptedVaultStore.applicationURL), keys: EnclaveKeyProvider(url: EncryptedVaultStore.applicationURL.deletingLastPathComponent().appendingPathComponent("key.enclave")), inbox: EncryptedCaptureInbox(directory: EncryptedVaultStore.applicationURL.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true)), pasteboard: .general)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var processLock: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let directory = EncryptedVaultStore.applicationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            processLock = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard processLock >= 0, flock(processLock, LOCK_EX | LOCK_NB) == 0 else {
                throw NSError(domain: "ClipVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "ClipVault is already running, or its storage folder is unavailable."])
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipVault encrypted clipboard history")
            button.toolTip = "ClipVault"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.contentSize = NSSize(width: 460, height: 620)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: HistoryView(model: model, openSettings: showSettings))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.lock() }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if self?.model.isUnlocked == true { self?.model.interact() }
            return event
        }
        model.startTimer()
        if model.isNew || CommandLine.arguments.contains("--open-on-launch") { togglePopover(nil) }
    }

    @objc func togglePopover(_ sender: Any?) {
        if sender is NSStatusBarButton, !model.isNew, !model.isUnlocked, !model.isUnlocking {
            showPopover()
            Task { @MainActor in
                await model.unlock()
                if model.isUnlocked { showPopover() }
            }
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        showPopover()
    }

    private func showPopover() {
        model.interact()
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillClose(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    func popoverDidClose(_ notification: Notification) { model.hideSensitivePreviews() }

    func showSettings() {
        guard model.interact() else { return }
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipVault Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsRoot(model: model))
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.lock()
        return .terminateNow
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
