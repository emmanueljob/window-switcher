import AppKit
import ApplicationServices
import Carbon

struct WindowItem {
    let element: AXUIElement?
    let app: NSRunningApplication
    let title: String
    var label: String {
        guard element != nil else { return "No open windows" }
        return title.isEmpty ? (app.localizedName ?? "Window") : title
    }
}

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result as? T
}

struct Shortcut: Equatable {
    let keyCode: UInt16
    let modifiers: CGEventFlags
    static let allowedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    static let standard = Shortcut(keyCode: 48, modifiers: .maskCommand)
    static let keys: [(String, UInt16)] = [("Tab", 48), ("Space", 49), ("`", 50)] +
        zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6].map(UInt16.init)).map { ($0.0, $0.1) }
    static let extraKeys: [(String, UInt16)] = zip(Array("1234567890").map(String.init), [18,19,20,21,23,22,26,28,25,29].map(UInt16.init)).map { ($0.0, $0.1) } +
        [122,120,99,118,96,97,98,100,101,109,103,111].enumerated().map { ("F\($0.offset + 1)", UInt16($0.element)) }
    static var allKeys: [(String, UInt16)] { keys + extraKeys }
    var isValid: Bool {
        !modifiers.intersection(Self.allowedModifiers).isEmpty &&
        modifiers.subtracting(Self.allowedModifiers).isEmpty && Self.allKeys.contains { $0.1 == keyCode }
    }
    var label: String {
        var result = ""
        if modifiers.contains(.maskControl) { result += "⌃" }
        if modifiers.contains(.maskAlternate) { result += "⌥" }
        if modifiers.contains(.maskCommand) { result += "⌘" }
        return result + (Self.allKeys.first { $0.1 == keyCode }?.0 ?? "Tab")
    }
    func matches(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Self.allowedModifiers) == modifiers
    }
    func isHeld(_ flags: CGEventFlags) -> Bool { flags.intersection(modifiers) == modifiers }
    static func load(from defaults: UserDefaults = .standard) -> Shortcut {
        guard defaults.object(forKey: "shortcut.key") != nil else { return .standard }
        let value = Shortcut(keyCode: UInt16(clamping: defaults.integer(forKey: "shortcut.key")),
                             modifiers: CGEventFlags(rawValue: UInt64(clamping: defaults.integer(forKey: "shortcut.modifiers"))))
        return value.isValid ? value : .standard
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: "shortcut.key")
        defaults.set(Int(modifiers.rawValue), forKey: "shortcut.modifiers")
    }
}

// The visual-effect material is composited separately from ordinary view layers.
// Mask the material itself so the window and its shadow share the rounded outline.
final class RoundedEffectView: NSVisualEffectView {
    private var maskedSize: NSSize = .zero

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMaterialMask()
    }

    override func layout() {
        super.layout()
        updateMaterialMask()
    }

    private func updateMaterialMask() {
        let size = bounds.size
        guard size.width > 0, size.height > 0, size != maskedSize else { return }
        maskedSize = size
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
            return true
        }
        window?.invalidateShadow()
    }
}

final class Switcher: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var timer: Timer?
    var windows: [WindowItem] = []
    var recent: [AXUIElement] = []
    var selected = 0
    var switching = false
    var loading = false
    var pendingOffset = 0
    var releasedWhileLoading = false
    var generation = 0
    var enabled = true
    var panel: NSPanel!
    var stack: NSStackView!
    var scroll: NSScrollView!
    var rowViews: [NSView] = []
    var toggleItem: NSMenuItem!
    var connectionItem: NSMenuItem!
    var lastHealth = ""
    var shortcut = Shortcut.load()
    var settingsWindow: NSWindow?
    var modifierButtons: [NSButton] = []
    var keyPicker: NSPopUpButton!
    var shortcutSummary: NSTextField!
    var settingsError: NSTextField!
    var previewMode = false
    var selectedTitle: NSTextField!
    var selectedApplication: NSTextField!
    var tileWidth: CGFloat = 116

    func reportHealth() {
        let trusted = AXIsProcessTrusted()
        let attached = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let health: String
        if !trusted { health = "Accessibility access needed" }
        else if IsSecureEventInputEnabled() { health = "Keyboard blocked by Secure Input" }
        else if !enabled { health = "Switcher paused" }
        else { health = attached ? "Ready · \(shortcut.label)" : "Keyboard disconnected" }
        connectionItem?.title = health
        guard health != lastHealth else { return }
        lastHealth = health
        logDiagnostic(health)
    }

    func logDiagnostic(_ message: String) {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WindowSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("status.log")
        let data = Data("\(Date()) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        if CommandLine.arguments.contains("--preview") {
            previewMode = true
            showDemo()
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Window Switcher")
        let menu = NSMenu()
        let name = NSMenuItem(title: "Window Switcher", action: nil, keyEquivalent: "")
        menu.addItem(name)
        connectionItem = NSMenuItem(title: "Checking connection…", action: nil, keyEquivalent: "")
        menu.addItem(connectionItem)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Enable Window Switcher", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let preview = NSMenuItem(title: "Preview Switcher", action: #selector(showDemo), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        let permissions = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccess), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        let retry = NSMenuItem(title: "Reconnect Keyboard Shortcut", action: #selector(reconnect), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Window Switcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
        logDiagnostic("Launched")
        if AXIsProcessTrusted() { connect() } else { requestAccess() }
        reportHealth()
        if CommandLine.arguments.contains("--settings") { showSettings() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.tap == nil && AXIsProcessTrusted() { self.connect() }
            self.reportHealth()
            if !self.switching && AXIsProcessTrusted() { self.rememberFocusedWindow() }
        }
    }

    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggle() {
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
        cancel()
        reportHealth()
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func reconnect() {
        cancel()
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        connect()
    }

    func connect() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Switcher>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            status.button?.toolTip = "Keyboard shortcut unavailable. Grant Accessibility access, then reconnect."
            return
        }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status.button?.toolTip = "\(shortcut.label): switch windows. Use the menu for settings or to quit."
    }

    // Runs on the main run loop. Return true only for keys consumed by the switcher.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard enabled else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let held = shortcut.isHeld(event.flags)
        if type == .flagsChanged {
            if switching && !held { commit() }
            return false
        }
        if key == Int64(shortcut.keyCode) && shortcut.matches(event.flags) {
            if type == .keyDown {
                logDiagnostic("Switcher shortcut received")
                step(reverse: event.flags.contains(.maskShift))
            }
            return true
        }
        if switching && key == 53 {
            if type == .keyDown { cancel() }
            return true
        }
        if switching && type == .keyDown && (key == 123 || key == 126 || key == 124 || key == 125) {
            step(reverse: key == 123 || key == 126)
            return true
        }
        return false
    }

    func remember(_ element: AXUIElement) {
        recent.removeAll { CFEqual($0, element) }
        recent.insert(element, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
    }

    func rememberFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.12)
        if let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) { remember(window) }
    }

    func collectWindows(recent: [AXUIElement]) -> [WindowItem] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { a, b in
                if a.processIdentifier == frontPID { return true }
                if b.processIdentifier == frontPID { return false }
                return (a.localizedName ?? "") < (b.localizedName ?? "")
            }
        var result: [WindowItem] = []
        for app in apps {
            let firstWindowIndex = result.count
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.12)
            let appWindows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            for window in appWindows {
                AXUIElementSetMessagingTimeout(window, 0.12)
                let role: String = attribute(window, kAXRoleAttribute) ?? ""
                let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
                guard role == kAXWindowRole, subrole != "AXFloatingWindow", subrole != "AXSystemFloatingWindow" else { continue }
                let title: String = attribute(window, kAXTitleAttribute) ?? ""
                result.append(WindowItem(element: window, app: app, title: title))
            }
            if result.count == firstWindowIndex {
                result.append(WindowItem(element: nil, app: app, title: ""))
            }
        }
        // A windowless foreground app is the current selection, ahead of past windows.
        return result.enumerated().sorted { a, b in
            let aIsCurrent = a.element.element == nil && a.element.app.processIdentifier == frontPID
            let bIsCurrent = b.element.element == nil && b.element.app.processIdentifier == frontPID
            if aIsCurrent != bIsCurrent { return aIsCurrent }
            let left = a.element.element.flatMap { window in recent.firstIndex { CFEqual($0, window) } } ?? (1000 + a.offset)
            let right = b.element.element.flatMap { window in recent.firstIndex { CFEqual($0, window) } } ?? (1000 + b.offset)
            return left < right
        }.map(\.element)
    }

    func step(reverse: Bool) {
        let delta = reverse ? -1 : 1
        if loading { pendingOffset += delta; return }
        if !switching {
            switching = true
            loading = true
            releasedWhileLoading = false
            pendingOffset = delta
            generation += 1
            let request = generation
            let history = recent
            // Other apps can be slow or unresponsive. Never query them in the event-tap callback.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let found = self.collectWindows(recent: history)
                DispatchQueue.main.async {
                    guard self.switching, self.generation == request else { return }
                    self.loading = false
                    self.windows = found
                    guard !found.isEmpty else { self.cancel(); return }
                    self.selected = ((self.pendingOffset % found.count) + found.count) % found.count
                    if self.releasedWhileLoading { self.commit(); return }
                    self.render()
                    self.showSelection()
                }
            }
            return
        }
        selected = (selected + delta + windows.count) % windows.count
        showSelection()
    }

    func showSelection() {
        highlight()
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
            panel.orderFrontRegardless()
        }
    }

    func cancel() {
        generation += 1
        loading = false
        switching = false
        panel.contentView?.gestureRecognizers = []
        panel.orderOut(nil)
        windows = []
    }

    func commit() {
        if loading { releasedWhileLoading = true; return }
        guard switching, windows.indices.contains(selected) else { cancel(); return }
        if previewMode { cancel(); return }
        let item = windows[selected]
        cancel()
        guard !item.app.isTerminated else { return }
        guard let window = item.element else {
            item.app.activate(options: [])
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        item.app.activate(options: [])
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raised == .success { remember(window) }
    }

    func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 204), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel("Window Switcher")
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 204))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        surface.layer?.cornerRadius = 26
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        panel.contentView = surface
        let effect = RoundedEffectView(frame: surface.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Only the material fades. Foreground icons and labels remain fully opaque.
        effect.alphaValue = 0.72
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.clear.cgColor
        surface.addSubview(effect)
        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        surface.addSubview(scroll)
        stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        scroll.documentView = stack
        selectedApplication = NSTextField(labelWithString: "")
        selectedApplication.font = .systemFont(ofSize: 14, weight: .semibold)
        selectedApplication.alignment = .center
        selectedApplication.lineBreakMode = .byTruncatingTail
        surface.addSubview(selectedApplication)
        selectedTitle = NSTextField(labelWithString: "")
        selectedTitle.font = .systemFont(ofSize: 12)
        selectedTitle.textColor = .secondaryLabelColor
        selectedTitle.alignment = .center
        selectedTitle.lineBreakMode = .byTruncatingMiddle
        surface.addSubview(selectedTitle)
    }

    func render() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rowViews = []
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let available = max(200, screen.visibleFrame.width - 100)
        let contentWidth = CGFloat(windows.count) * (tileWidth + 8) - 8
        let width = min(available, max(260, contentWidth + 40))
        panel.setContentSize(NSSize(width: width, height: 204))
        scroll.frame = NSRect(x: 20, y: 64, width: width - 40, height: 120)
        stack.frame = NSRect(x: 0, y: 0, width: max(contentWidth, width - 40), height: 116)
        selectedApplication.frame = NSRect(x: 24, y: 37, width: width - 48, height: 20)
        selectedTitle.frame = NSRect(x: 24, y: 16, width: width - 48, height: 17)
        let counts = Dictionary(grouping: windows.filter { $0.element != nil }, by: { $0.app.processIdentifier })
        var positions: [pid_t: Int] = [:]
        for item in windows {
            let tile = NSView(frame: NSRect(x: 0, y: 0, width: tileWidth, height: 116))
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 18
            tile.setAccessibilityElement(true)
            tile.setAccessibilityRole(.button)
            tile.setAccessibilityLabel("\(item.app.localizedName ?? "Application"), \(item.label)")
            tile.toolTip = item.label
            let icon = NSImageView(frame: NSRect(x: 12, y: 14, width: 92, height: 92))
            icon.image = item.app.icon
            icon.imageScaling = .scaleProportionallyUpOrDown
            tile.addSubview(icon)
            let pid = item.app.processIdentifier
            positions[pid, default: 0] += 1
            if item.element != nil, let count = counts[pid]?.count, count > 1 {
                let badge = NSTextField(labelWithString: "\(positions[pid]!) / \(count)")
                badge.alignment = .center
                badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
                badge.textColor = .white
                badge.drawsBackground = true
                badge.backgroundColor = NSColor.black.withAlphaComponent(0.65)
                badge.wantsLayer = true
                badge.layer?.cornerRadius = 8
                badge.layer?.masksToBounds = true
                badge.frame = NSRect(x: 64, y: 8, width: 44, height: 17)
                tile.addSubview(badge)
            }
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: tileWidth), tile.heightAnchor.constraint(equalToConstant: 116)])
            stack.addArrangedSubview(tile)
            rowViews.append(tile)
        }
        stack.layoutSubtreeIfNeeded()
    }

    func highlight() {
        for (index, view) in rowViews.enumerated() {
            view.layer?.backgroundColor = index == selected ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
            view.layer?.borderWidth = index == selected ? 1 : 0
            view.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
        }
        if rowViews.indices.contains(selected) {
            stack.scrollToVisible(rowViews[selected].frame.insetBy(dx: -4, dy: 0))
            selectedApplication.stringValue = windows[selected].app.localizedName ?? "Application"
            selectedTitle.stringValue = windows[selected].label
        }
    }

    @objc func showSettings() {
        cancel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 346), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Window Switcher Settings"
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            func label(_ text: String, _ frame: NSRect, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular) -> NSTextField {
                let field = NSTextField(wrappingLabelWithString: text)
                field.font = .systemFont(ofSize: size, weight: weight)
                field.frame = frame
                content.addSubview(field)
                return field
            }
            _ = label("Keyboard shortcut", NSRect(x: 28, y: 290, width: 404, height: 26), 20, .semibold)
            _ = label("Hold these keys", NSRect(x: 28, y: 251, width: 404, height: 19))
            modifierButtons = [("⌘ Command", CGEventFlags.maskCommand), ("⌥ Option", .maskAlternate), ("⌃ Control", .maskControl)].enumerated().map { index, pair in
                let button = NSButton(checkboxWithTitle: pair.0, target: self, action: #selector(shortcutEdited))
                button.frame = NSRect(x: 28 + index * 138, y: 220, width: 135, height: 24)
                button.tag = Int(pair.1.rawValue)
                content.addSubview(button)
                return button
            }
            _ = label("Then press", NSRect(x: 28, y: 177, width: 100, height: 20))
            keyPicker = NSPopUpButton(frame: NSRect(x: 132, y: 173, width: 170, height: 28), pullsDown: false)
            for key in Shortcut.allKeys { keyPicker.addItem(withTitle: key.0); keyPicker.lastItem?.tag = Int(key.1) }
            keyPicker.target = self
            keyPicker.action = #selector(shortcutEdited)
            content.addSubview(keyPicker)
            shortcutSummary = label("", NSRect(x: 322, y: 177, width: 110, height: 24), 16, .medium)
            _ = label("Release the held keys to select a window. Add Shift to go backward; Escape cancels.", NSRect(x: 28, y: 114, width: 404, height: 44))
            settingsError = label("", NSRect(x: 28, y: 72, width: 404, height: 36), 11)
            settingsError.textColor = .secondaryLabelColor
            let reset = NSButton(title: "Restore Default", target: self, action: #selector(resetShortcut))
            reset.frame = NSRect(x: 24, y: 23, width: 140, height: 32)
            content.addSubview(reset)
            let apply = NSButton(title: "Save Shortcut", target: self, action: #selector(saveShortcut))
            apply.bezelStyle = .rounded
            apply.frame = NSRect(x: 298, y: 23, width: 138, height: 32)
            apply.keyEquivalent = "\r"
            content.addSubview(apply)
            settingsWindow = window
        }
        updateSettingsControls()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func updateSettingsControls() {
        for button in modifierButtons { button.state = shortcut.modifiers.contains(CGEventFlags(rawValue: UInt64(button.tag))) ? .on : .off }
        keyPicker.selectItem(withTag: Int(shortcut.keyCode))
        shortcutSummary.stringValue = shortcut.label
        settingsError.stringValue = "This overrides the selected shortcut while Window Switcher is enabled."
    }

    @objc func shortcutEdited() {
        let flags = modifierButtons.filter { $0.state == .on }.reduce(CGEventFlags()) { $0.union(CGEventFlags(rawValue: UInt64($1.tag))) }
        let candidate = Shortcut(keyCode: UInt16(keyPicker.selectedTag()), modifiers: flags)
        shortcutSummary.stringValue = candidate.label
        settingsError.stringValue = candidate.isValid ? "Click Save Shortcut to apply this change." : "Select at least one held key."
    }

    @objc func saveShortcut() {
        let flags = modifierButtons.filter { $0.state == .on }.reduce(CGEventFlags()) { $0.union(CGEventFlags(rawValue: UInt64($1.tag))) }
        let choice = Shortcut(keyCode: UInt16(keyPicker.selectedTag()), modifiers: flags)
        guard choice.isValid else {
            settingsError.stringValue = "Select at least one held key: Command, Option, or Control."
            return
        }
        cancel()
        shortcut = choice
        shortcut.save()
        updateSettingsControls()
        settingsError.stringValue = "Saved. Your shortcut is now \(shortcut.label)."
        status.button?.toolTip = "\(shortcut.label): switch windows."
        reportHealth()
    }

    @objc func resetShortcut() {
        shortcut = .standard
        shortcut.save()
        cancel()
        updateSettingsControls()
        reportHealth()
    }

    @objc func showDemo() {
        cancel()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.prefix(5)
        windows = apps.map { WindowItem(element: AXUIElementCreateApplication($0.processIdentifier), app: $0, title: $0.localizedName == "Google Chrome" ? "Browser — Window 1" : ($0.localizedName ?? "Window")) }
        if let chrome = apps.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            windows.insert(WindowItem(element: AXUIElementCreateApplication(chrome.processIdentifier), app: chrome, title: "Browser — Window 2"), at: min(1, windows.count))
        }
        if let app = apps.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) ?? apps.first(where: { $0.bundleIdentifier != "com.google.Chrome" }) {
            windows.removeAll { $0.app.processIdentifier == app.processIdentifier }
            windows.append(WindowItem(element: nil, app: app, title: ""))
        }
        guard !windows.isEmpty else { return }
        selected = min(1, windows.count - 1)
        render()
        showSelection()
        let dismiss = NSClickGestureRecognizer(target: self, action: #selector(dismissDemo))
        panel.contentView?.addGestureRecognizer(dismiss)
    }

    @objc func dismissDemo() {
        cancel()
        if previewMode { NSApp.terminate(nil) }
    }

}

func runSelfTests() {
    let owner = Switcher()
    owner.shortcut = .standard
    owner.makePanel()
    let app = NSRunningApplication.current
    let element = AXUIElementCreateApplication(getpid())
    owner.windows = (0..<3).map { WindowItem(element: element, app: app, title: "Test \($0)") }
    owner.switching = true
    owner.render()
    func key(_ code: CGKeyCode, flags: CGEventFlags = .maskCommand) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return event
    }
    precondition(owner.handle(.keyDown, key(48)))
    precondition(owner.selected == 1, "Tab should advance")
    precondition(owner.handle(.keyDown, key(48, flags: [.maskCommand, .maskShift])))
    precondition(owner.selected == 0, "Shift Tab should reverse")
    _ = owner.handle(.keyDown, key(48, flags: [.maskCommand, .maskShift]))
    precondition(owner.selected == 2, "Reverse should wrap")
    precondition(!owner.handle(.keyDown, key(0)), "Unrelated shortcuts must pass through")
    precondition(owner.handle(.keyDown, key(53)))
    precondition(!owner.switching && !owner.panel.isVisible, "Escape should cancel")
    owner.enabled = false
    precondition(!owner.handle(.keyDown, key(48)), "Disabled switcher must pass Command Tab through")
    owner.enabled = true
    owner.switching = true
    owner.loading = true
    _ = owner.handle(.flagsChanged, key(55, flags: []))
    precondition(owner.releasedWhileLoading, "Fast release must wait for discovery")
    _ = owner.handle(.keyDown, key(53))
    precondition(!owner.loading && !owner.switching, "Escape must cancel pending discovery")
    let defaults = UserDefaults(suiteName: "local.window-switcher.self-test")!
    defaults.removePersistentDomain(forName: "local.window-switcher.self-test")
    defer { defaults.removePersistentDomain(forName: "local.window-switcher.self-test") }
    let custom = Shortcut(keyCode: 49, modifiers: [.maskControl, .maskAlternate])
    precondition(custom.isValid)
    custom.save(to: defaults)
    precondition(Shortcut.load(from: defaults) == custom, "Shortcut must persist")
    precondition(!Shortcut(keyCode: 48, modifiers: []).isValid, "Unmodified shortcut must be rejected")
    owner.shortcut = custom
    owner.windows = (0..<3).map { WindowItem(element: element, app: app, title: "Test \($0)") }
    owner.switching = true
    owner.render()
    owner.selected = 0
    precondition(!owner.handle(.keyDown, key(48)), "Old shortcut must pass through")
    precondition(owner.handle(.keyDown, key(49, flags: [.maskControl, .maskAlternate])))
    precondition(owner.selected == 1, "Custom shortcut must advance")
    _ = owner.handle(.keyDown, key(49, flags: [.maskControl, .maskAlternate, .maskShift]))
    precondition(owner.selected == 0, "Custom shortcut must support reverse")
    precondition(!owner.handle(.keyDown, key(49, flags: [.maskControl, .maskAlternate, .maskCommand])), "Extra modifiers must pass through")
    owner.loading = true
    _ = owner.handle(.flagsChanged, key(58, flags: .maskControl))
    precondition(owner.releasedWhileLoading, "Releasing a configured modifier must commit")
    owner.cancel()
    owner.windows = (0..<40).map { WindowItem(element: element, app: app, title: "Window \($0)") }
    owner.render()
    owner.selected = 39
    owner.highlight()
    precondition(owner.panel.frame.width <= NSScreen.main!.visibleFrame.width, "Many windows must fit the screen")
    precondition(owner.stack.orientation == .horizontal)
    let noWindows = WindowItem(element: nil, app: app, title: "")
    precondition(noWindows.label == "No open windows")
    owner.windows = [noWindows]
    owner.selected = 0
    owner.render()
    owner.highlight()
    precondition(owner.selectedTitle.stringValue == "No open windows")
    precondition(owner.rowViews.count == 1, "Windowless apps must be selectable")
    print("PASS: selection, cancellation, passthrough, custom shortcuts, persistence, modifier release, and horizontal overflow")
}

if CommandLine.arguments.contains("--self-test") {
    _ = NSApplication.shared
    runSelfTests()
    exit(0)
}

let application = NSApplication.shared
let delegate = Switcher()
application.delegate = delegate
application.run()
