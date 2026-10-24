import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// Turns the single Flutter window into the floating prompter and back.
/// Logic ported from the Swift POC (PrompterModel placement / capture code).
public class EchoprompterWindowPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private var window: NSWindow? { NSApp.windows.first(where: { $0.contentViewController is FlutterViewController }) }

    private var studioFrame: NSRect?
    private var studioStyle: NSWindow.StyleMask?
    private var studioLevel: NSWindow.Level = .normal
    private var studioBehavior: NSWindow.CollectionBehavior = []
    private var inPrompter = false
    private var applying = false
    private var options: [String: Any] = [:]
    private var moveWork: DispatchWorkItem?
    private var notchExtra: CGFloat?
    private var gesture: (frame: NSRect, mouse: NSPoint, extra: CGFloat)?
    private var observers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyNames: [UInt32: String] = [:]
    private var hotKeyHandler: EventHandlerRef?
    // The Carbon event handler is a C function pointer and cannot capture self.
    private static weak var active: EchoprompterWindowPlugin?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        Self.active = self
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.echoprompter/window", binaryMessenger: registrar.messenger)
        let instance = EchoprompterWindowPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "enterPrompter": options = args; notchExtra = nil; enter(); result(nil)
        case "update": options = args; notchExtra = nil; if inPrompter { apply(animated: true) }; result(nil)
        case "exitPrompter": exit(); result(nil)
        case "revealStudio": revealStudio(); result(nil)
        case "gestureBegin":
            if let w = window { gesture = (w.frame, NSEvent.mouseLocation, notchExtra ?? num("notchHeight", 150)) }
            result(nil)
        case "dragUpdate":
            if let w = window, let g = gesture {
                let m = NSEvent.mouseLocation
                applying = true
                w.setFrameOrigin(NSPoint(x: g.frame.minX + m.x - g.mouse.x, y: g.frame.minY + m.y - g.mouse.y))
                applying = false
            }
            result(nil)
        case "resizeUpdate":
            resize(edge: call.arguments as? String ?? "br")
            result(nil)
        case "gestureEnd":
            gesture = nil
            finishGesture()
            result(nil)
        case "supportsCaptureHiding": result(true)
        case "legacyDefaults":
            // Settings written by the Swift proof of concept (same bundle ID).
            let d = UserDefaults.standard
            var out: [String: Any] = [:]
            if let v = d.string(forKey: "EchoPrompter.placement.v1") { out["placement"] = v }
            if let v = d.string(forKey: "EchoPrompter.corner.v1") { out["corner"] = v }
            if d.object(forKey: "EchoPrompter.hideFromCapture.v1") != nil { out["hideFromCapture"] = d.bool(forKey: "EchoPrompter.hideFromCapture.v1") }
            result(out)
        case "hasHardwareNotch": result((NSScreen.main?.safeAreaInsets.top ?? 0) > 0)
        case "setTrayMenu": result(setTrayMenu(args["items"] as? [[String: Any]]))
        case "registerHotkeys": result(registerHotkeys(args["bindings"] as? [[String: Any]] ?? []))
        case "unregisterHotkeys": unregisterHotkeys(); result(nil)
        case "setPrompterVisible":
            if let w = window, inPrompter {
                if call.arguments as? Bool ?? true { w.orderFrontRegardless() } else { w.orderOut(nil) }
            }
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Enter / exit

    private func enter() {
        guard let w = window else { return }
        if !inPrompter {
            studioFrame = w.frame
            studioStyle = w.styleMask
            studioLevel = w.level
            studioBehavior = w.collectionBehavior
            inPrompter = true
            startObserving()
        }
        // Not movable-by-background: that would swallow Flutter's clicks. Dragging
        // and resizing are driven from Flutter via gestureBegin/dragUpdate/resizeUpdate.
        w.isMovableByWindowBackground = false
        w.styleMask = [.borderless, .resizable, .fullSizeContentView]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set capture visibility before ordering front: some capture tools
        // snapshot the window list when a stream starts.
        applyCapture(w)
        w.alphaValue = 1
        apply(animated: false)
        w.makeKeyAndOrderFront(nil)
    }

    private func exit() {
        guard let w = window, inPrompter else { return }
        inPrompter = false
        stopObserving()
        w.sharingType = .readOnly
        w.styleMask = studioStyle ?? [.titled, .closable, .miniaturizable, .resizable]
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        w.level = studioLevel
        w.collectionBehavior = studioBehavior
        w.hasShadow = true
        w.minSize = NSSize(width: 820, height: 620)
        w.maxSize = NSSize(width: 100_000, height: 100_000)
        // Restore Studio's frame; never leave it at a prompter-sized frame.
        var f = studioFrame ?? w.frame
        if f.width < 820 || f.height < 620, let v = (w.screen ?? NSScreen.main)?.visibleFrame {
            let width = min(1100, v.width), height = min(760, v.height)
            f = NSRect(x: v.midX - width / 2, y: v.midY - height / 2, width: width, height: height)
        }
        // Stay invisible while Flutter swaps the prompter for Studio, so the
        // old content is never seen at the new size. `revealStudio` ends this;
        // the timer is a fallback.
        w.alphaValue = 0
        w.setFrame(f, display: true, animate: false)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.revealStudio() }
    }

    private func revealStudio() {
        guard !inPrompter, let w = window, w.alphaValue < 1 else { return }
        w.alphaValue = 1
    }

    private func applyCapture(_ w: NSWindow) {
        w.sharingType = (options["hideFromCapture"] as? Bool ?? true) ? .none : .readOnly
    }

    // MARK: Placement

    private func num(_ k: String, _ d: CGFloat) -> CGFloat { (options[k] as? NSNumber).map { CGFloat(truncating: $0) } ?? d }

    private func screenForPrompter() -> NSScreen? {
        if let s = window?.screen { return s }
        return NSScreen.main
    }

    static func displayKey(_ screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return String(n.uint32Value)
        }
        return screen.localizedName
    }

    private func hardwareNotchWidth(_ s: NSScreen) -> CGFloat? {
        guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        return max(0, s.frame.width - l.width - r.width)
    }

    private func notchFrame(_ s: NSScreen) -> NSRect {
        let inset = s.safeAreaInsets.top
        let hw = hardwareNotchWidth(s) ?? 0
        let width = min(s.frame.width, max(num("notchWidth", 420), hw + 120))
        let height = inset + (notchExtra ?? num("notchHeight", 90))
        // Without a notch, dock under the menu bar instead of the physical top.
        let top = inset > 0 ? s.frame.maxY : s.visibleFrame.maxY
        return NSRect(x: s.frame.midX - width / 2, y: top - height, width: width, height: height)
    }

    private func cornerSize(_ s: NSScreen) -> CGSize {
        let v = s.visibleFrame
        return CGSize(width: min(max(num("cornerWidth", 420), 300), v.width * 0.6),
                      height: min(max(num("cornerHeight", 240), 160), v.height * 0.6))
    }

    private func cornerFrame(_ s: NSScreen, _ corner: String) -> NSRect {
        let v = s.visibleFrame, size = cornerSize(s), m: CGFloat = 16
        let left = corner.hasSuffix("Left"), top = corner.hasPrefix("top")
        return NSRect(x: left ? v.minX + m : v.maxX - m - size.width,
                      y: top ? v.maxY - m - size.height : v.minY + m,
                      width: size.width, height: size.height)
    }

    private func floatingFrame(_ s: NSScreen) -> NSRect {
        let v = s.visibleFrame
        var f: NSRect
        if let a = options["floatingFrame"] as? [NSNumber], a.count == 4 {
            // Saved frame is top-left relative; convert to AppKit's bottom-left.
            let w = CGFloat(truncating: a[2]), h = CGFloat(truncating: a[3])
            f = NSRect(x: s.frame.minX + CGFloat(truncating: a[0]),
                       y: s.frame.maxY - CGFloat(truncating: a[1]) - h, width: w, height: h)
        } else {
            let size = NSSize(width: 900, height: 360)
            f = NSRect(x: v.midX - size.width / 2, y: v.maxY - size.height - 40, width: size.width, height: size.height)
        }
        // Keep at least 80 × 40 points reachable after display changes.
        f.size.width = min(f.width, v.width); f.size.height = min(f.height, v.height)
        f.origin.x = min(max(f.minX, v.minX - f.width + 80), v.maxX - 80)
        f.origin.y = min(max(f.minY, v.minY - f.height + 40), v.maxY - f.height)
        return f
    }

    private func apply(animated: Bool) {
        guard let w = window, let s = screenForPrompter() else { return }
        applyCapture(w)
        let frame: NSRect
        switch options["placement"] as? String ?? "floating" {
        case "notch":
            frame = notchFrame(s)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            w.hasShadow = false
            w.minSize = frame.size; w.maxSize = frame.size
        case "corner":
            frame = cornerFrame(s, options["corner"] as? String ?? "topRight")
            w.level = .floating
            w.hasShadow = true
            w.minSize = NSSize(width: 300, height: 160)
            w.maxSize = NSSize(width: s.visibleFrame.width * 0.6, height: s.visibleFrame.height * 0.6)
        default:
            frame = floatingFrame(s)
            w.level = .floating
            w.hasShadow = true
            w.minSize = NSSize(width: 360, height: 200)
            w.maxSize = NSSize(width: 10_000, height: 10_000)
        }
        // Programmatic moves must not be mistaken for presenter drags.
        applying = true
        w.setFrame(frame, display: true, animate: animated && w.isVisible)
        w.invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.3 : 0.05)) { [weak self] in self?.applying = false }
    }

    // MARK: Observing moves, displays and Spaces

    private func startObserving() {
        let nc = NotificationCenter.default
        let moved: (Notification) -> Void = { [weak self] _ in self?.userMovedWindow() }
        observers = [
            nc.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main, using: moved),
            nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main, using: moved),
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.apply(animated: false)
            },
            nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.inPrompter, let w = self.window else { return }
                self.applyCapture(w); w.orderFrontRegardless()
            },
        ]
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        moveWork?.cancel()
    }

    private func userMovedWindow() {
        guard inPrompter, !applying, let w = window, let s = w.screen else { return }
        let placement = options["placement"] as? String ?? "floating"
        guard placement != "notch" else { return }
        moveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.applying else { return }
            var corner: String?
            if placement == "corner" {
                corner = self.nearestCorner(w.frame, on: s)
                self.options["corner"] = corner
                self.apply(animated: true)
            }
            let f = w.frame
            let rel = [f.minX - s.frame.minX, s.frame.maxY - f.maxY, f.width, f.height]
            var payload: [String: Any] = ["display": Self.displayKey(s), "frame": rel]
            if let corner { payload["corner"] = corner }
            self.channel.invokeMethod("frameChanged", arguments: payload)
        }
        moveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func resize(edge: String) {
        guard let w = window, let g = gesture else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - g.mouse.x, dy = m.y - g.mouse.y
        if options["placement"] as? String == "notch" {
            notchExtra = min(max(g.extra - dy, 80), 400)
            apply(animated: false)
            return
        }
        var f = g.frame
        if edge.contains("r") { f.size.width = g.frame.width + dx }
        if edge.contains("l") { f.size.width = g.frame.width - dx }
        if edge.contains("b") { f.size.height = g.frame.height - dy }
        f.size.width = min(max(f.width, w.minSize.width), w.maxSize.width)
        f.size.height = min(max(f.height, w.minSize.height), w.maxSize.height)
        // The top edge never moves; the left edge keeps the right edge fixed.
        f.origin.x = edge.contains("l") ? g.frame.maxX - f.width : g.frame.minX
        f.origin.y = g.frame.maxY - f.height
        applying = true
        w.setFrame(f, display: true)
        applying = false
    }

    private func finishGesture() {
        guard inPrompter, let w = window, let s = w.screen else { return }
        if options["placement"] as? String == "notch" {
            channel.invokeMethod("frameChanged", arguments: [
                "display": Self.displayKey(s),
                "frame": [0, 0, w.frame.width, w.frame.height],
                "notchHeight": notchExtra ?? num("notchHeight", 150),
            ])
            return
        }
        userMovedWindow()
    }

    private func nearestCorner(_ f: NSRect, on s: NSScreen) -> String {
        let v = s.visibleFrame
        let left = f.midX < v.midX, top = f.midY > v.midY
        return (top ? "top" : "bottom") + (left ? "Left" : "Right")
    }

    // MARK: Menu-bar icon

    /// Shows a menu-bar icon with [items], or removes it when nil. Returns
    /// whether the icon is showing.
    private func setTrayMenu(_ items: [[String: Any]]?) -> Bool {
        guard let items else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return false
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button, button.image == nil {
            if let image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "EchoPrompter") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "EP"
            }
            button.toolTip = "EchoPrompter"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            if entry["separator"] as? Bool ?? false {
                menu.addItem(.separator())
                continue
            }
            let row = NSMenuItem(title: entry["title"] as? String ?? "", action: #selector(trayItemChosen(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = entry["id"] as? String
            row.isEnabled = entry["enabled"] as? Bool ?? true
            row.state = (entry["checked"] as? Bool ?? false) ? .on : .off
            menu.addItem(row)
        }
        item.menu = menu
        return true
    }

    @objc private func trayItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        channel.invokeMethod("trayAction", arguments: id)
    }

    // MARK: Global shortcuts

    private static let keyCodes: [String: Int] = [
        "space": 49, "up": 126, "down": 125, "left": 123, "right": 124,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static func carbonModifiers(_ names: [String]) -> UInt32 {
        var flags = 0
        for name in names {
            switch name {
            case "ctrl": flags |= controlKey
            case "alt": flags |= optionKey
            case "shift": flags |= shiftKey
            case "meta": flags |= cmdKey
            default: break
            }
        }
        return UInt32(flags)
    }

    /// Registers system-wide shortcuts (no Accessibility permission needed).
    /// Returns which ids succeeded.
    private func registerHotkeys(_ bindings: [[String: Any]]) -> [String: Bool] {
        unregisterHotkeys()
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                if status == noErr { EchoprompterWindowPlugin.active?.hotKeyPressed(pressed.id) }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        var outcome: [String: Bool] = [:]
        for (index, binding) in bindings.enumerated() {
            guard let id = binding["id"] as? String else { continue }
            guard let key = binding["key"] as? String, let code = Self.keyCodes[key] else {
                outcome[id] = false
                continue
            }
            let hotKeyID = EventHotKeyID(signature: OSType(0x4550_4B59), id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), Self.carbonModifiers(binding["mods"] as? [String] ?? []),
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                hotKeyNames[hotKeyID.id] = id
                outcome[id] = true
            } else {
                outcome[id] = false
            }
        }
        return outcome
    }

    private func unregisterHotkeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        hotKeyNames = [:]
    }

    fileprivate func hotKeyPressed(_ id: UInt32) {
        guard let name = hotKeyNames[id] else { return }
        DispatchQueue.main.async { [weak self] in self?.channel.invokeMethod("hotkey", arguments: name) }
    }
}
