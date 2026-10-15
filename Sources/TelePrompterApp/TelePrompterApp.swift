import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let restoreEchoPromptWorkspace = Notification.Name("restoreEchoPromptWorkspace")
}

@main
struct EchoPromptApp: App {
    @StateObject private var model = PrompterModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("EchoPrompt") {
            EditorView(model: model)
                .frame(minWidth: 660, minHeight: 520)
        }
        .defaultSize(width: 760, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Script Studio") {
                    NotificationCenter.default.post(name: .restoreEchoPromptWorkspace, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Makes a Swift Package-launched app behave like a normal Mac app: it gets
/// focus on launch and when its Dock icon is clicked again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click should keep a visible floating prompter in presentation
        // mode. Only restore Script Studio if there is no visible prompt.
        let promptIsVisible = NSApp.windows.contains { $0 is NSPanel && $0.isVisible }
        guard !promptIsVisible else {
            // Returning false prevents AppKit's default untitled-window action.
            return false
        }
        NotificationCenter.default.post(name: .restoreEchoPromptWorkspace, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}

struct SavedScript: Codable, Identifiable, Equatable {
    var id: UUID
    var body: String
    var savedAt: Date
    var fileName: String?
    init(body: String, fileName: String? = nil, savedAt: Date = .now) { self.id = UUID(); self.body = body; self.fileName = fileName; self.savedAt = savedAt }
    var title: String { body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled script" }
}

enum PromptTheme: String, CaseIterable, Identifiable {
    case midnight, paper, ember
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var background: Color { switch self { case .midnight: .black; case .paper: Color(red: 0.96, green: 0.93, blue: 0.84); case .ember: Color(red: 0.15, green: 0.035, blue: 0.02) } }
    var text: Color { self == .paper ? .black : .white }
}

enum StudioAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

enum PromptControlMode: String, CaseIterable, Identifiable {
    case normal, voice, recordedAudio
    var id: String { rawValue }
    var name: String {
        switch self {
        case .normal: "Normal scrolling"
        case .voice: "Voice control"
        case .recordedAudio: "Recorded audio"
        }
    }
}

@MainActor
final class PrompterModel: ObservableObject {
    @Published var script = "Welcome to EchoPrompt.\n\nPaste your script here, then start EchoPrompt when you are ready."
    @Published var fontSize: Double = 50
    @Published var speed: Double = 24
    @Published var lineSpacing: Double = 1.28
    @Published var opacity: Double = 0.92
    @Published var mirrorText = false
    /// Normal scrolling is deliberately the default; modes are mutually exclusive.
    @Published var controlMode: PromptControlMode = .normal
    @Published var audioFileURL: URL?
    /// Lets the presenter click through the floating prompt onto VS Code.
    @Published var clickThroughPresentation = false {
        didSet { panel?.ignoresMouseEvents = clickThroughPresentation }
    }
    @Published var showRecordingTip = true
    @Published var promptTheme: PromptTheme = .midnight
    @Published var studioAppearance: StudioAppearance = .dark
    @Published private(set) var history: [SavedScript] = []

    private var panel: NSPanel?
    private weak var workspaceWindow: NSWindow?
    private let historyKey = "EchoPrompt.scriptHistory.v1"
    private var activeHistoryID: UUID?

    var promptBackground: Color { promptTheme.background }
    var promptText: Color { promptTheme.text }
    var scriptLibraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoPrompt Scripts", isDirectory: true)
    }

    private func fileURL(for item: SavedScript) -> URL {
        scriptLibraryURL.appendingPathComponent(item.fileName ?? "\(item.id.uuidString).txt")
    }

    private func fileName(for text: String, excluding itemID: UUID? = nil, currentFileName: String? = nil) -> String {
        let heading = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        let invalid = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let safe = heading.components(separatedBy: invalid).joined()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let stem = String(safe.prefix(60)).isEmpty ? "EchoPrompt-script" : String(safe.prefix(60))
        var candidate = "\(stem).txt"
        var number = 2
        let used = Set(history.filter { $0.id != itemID }.compactMap(\.fileName))
        while used.contains(candidate) || (candidate != currentFileName && FileManager.default.fileExists(atPath: scriptLibraryURL.appendingPathComponent(candidate).path)) {
            candidate = "\(stem)-\(number).txt"
            number += 1
        }
        return candidate
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey), let items = try? JSONDecoder().decode([SavedScript].self, from: data) { history = items }
    }

    func saveHistoryNow() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item: SavedScript
        if let activeHistoryID, let index = history.firstIndex(where: { $0.id == activeHistoryID }) {
            // Preserve the loaded script's identity instead of creating a duplicate.
            let oldURL = fileURL(for: history[index])
            history[index].body = script
            history[index].savedAt = .now
            history[index].fileName = fileName(for: script, excluding: history[index].id, currentFileName: history[index].fileName)
            if oldURL != fileURL(for: history[index]) { try? FileManager.default.removeItem(at: oldURL) }
            item = history[index]
        } else {
            history.removeAll { $0.body == script }
            let saved = SavedScript(body: script, fileName: fileName(for: script))
            history.insert(saved, at: 0)
            activeHistoryID = saved.id
            item = saved
        }
        do {
            try FileManager.default.createDirectory(at: scriptLibraryURL, withIntermediateDirectories: true)
            try script.write(to: fileURL(for: item), atomically: true, encoding: .utf8)
        } catch {
            // The history list remains available even if Finder storage is temporarily unavailable.
        }
        history = Array(history.prefix(20))
        persistHistory()
    }

    func loadHistory(_ item: SavedScript) {
        activeHistoryID = item.id
        script = (try? String(contentsOf: fileURL(for: item), encoding: .utf8)) ?? item.body
    }
    func deleteHistory(_ item: SavedScript) {
        history.removeAll { $0.id == item.id }
        if activeHistoryID == item.id { activeHistoryID = nil }
        try? FileManager.default.removeItem(at: fileURL(for: item))
        persistHistory()
    }
    func revealScriptLibrary() {
        try? FileManager.default.createDirectory(at: scriptLibraryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(scriptLibraryURL)
    }

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose recorded audio"
        panel.message = "Choose an audio file for future script synchronization."
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { audioFileURL = panel.url }
    }
    private func persistHistory() { if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) } }

    func openPrompter() {
        saveHistoryNow()
        workspaceWindow = NSApp.keyWindow
        workspaceWindow?.orderOut(nil)
        if let panel { panel.ignoresMouseEvents = clickThroughPresentation; panel.makeKeyAndOrderFront(nil); return }
        let promptSize = NSSize(width: 900, height: 360)
        // AppKit's coordinate system starts at the bottom. Position the panel
        // 40 points below the usable top edge, near a laptop's camera line.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - promptSize.width / 2,
            y: screen.maxY - promptSize.height - 40
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: promptSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "EchoPrompt"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = clickThroughPresentation
        panel.contentView = NSHostingView(rootView: PromptView(model: self))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func closePrompter() {
        panel?.orderOut(nil)
        restoreWorkspace()
    }

    func restoreWorkspace() {
        clickThroughPresentation = false
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct EditorView: View {
    @ObservedObject var model: PrompterModel
    @State private var showSavedScripts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    HStack(spacing: 11) {
                        Image(systemName: "text.quote")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("EchoPrompt").font(.title2.weight(.bold))
                            Text("Script studio").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { showSavedScripts.toggle() } label: { Label("Saved scripts", systemImage: "bookmark") }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $showSavedScripts, arrowEdge: .bottom) {
                            SavedScriptsPopover(model: model)
                        }
                    Button { model.openPrompter() } label: { Label("Start EchoPrompt", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [.command])
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Your script").font(.headline); Spacer(); Text("\(model.script.split(whereSeparator: { $0.isWhitespace }).count) words").font(.subheadline).foregroundStyle(.secondary) }
                    TextEditor(text: $model.script)
                        .font(.system(size: 18))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 240, maxHeight: 330)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack(alignment: .top, spacing: 14) {
                    EditorCard(title: "Reading pace", icon: "gauge.with.dots.needle.33percent") {
                        ControlLabel(title: "Text size", value: model.fontSize, suffix: " pt")
                        SmoothSlider(value: $model.fontSize, range: 24...110)
                        ControlLabel(title: "Line spacing", value: model.lineSpacing, suffix: "×")
                        SmoothSlider(value: $model.lineSpacing, range: 0.9...2.0)
                        ControlLabel(title: "Scroll speed", value: model.speed, suffix: " px/s")
                        SmoothSlider(value: $model.speed, range: 5...100)
                    }
                    EditorCard(title: "Control mode", icon: "hand.tap.fill") {
                        Picker("Control mode", selection: $model.controlMode) {
                            Text("Normal").tag(PromptControlMode.normal)
                            Text("Voice").tag(PromptControlMode.voice)
                            Text("Audio").tag(PromptControlMode.recordedAudio)
                        }
                        .pickerStyle(.segmented)
                        if model.controlMode == .recordedAudio {
                            HStack {
                                Button("Choose audio file…") { model.chooseAudioFile() }.buttonStyle(.bordered)
                                Text(model.audioFileURL?.lastPathComponent ?? "No file selected")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("Audio-synced scrolling will be added next. Your selected file stays local to this Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.controlMode == .voice {
                            Text("Voice control will use live speech commands when implemented.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Automatic scrolling with on-screen controls.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Divider().padding(.top, 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle("Click through prompt", isOn: $model.clickThroughPresentation)
                                .font(.subheadline)
                            Text("Useful while working in VS Code. Return via Edit script or EchoPrompt ▸ Open Script Studio (⇧⌘E).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    EditorCard(title: "Appearance", icon: "paintpalette.fill") {
                        Picker("Prompt theme", selection: $model.promptTheme) {
                            ForEach(PromptTheme.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Studio appearance", selection: $model.studioAppearance) {
                            ForEach(StudioAppearance.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    Text("Press ⌘↩ to start EchoPrompt in a focused floating window.")
                }.font(.subheadline).foregroundStyle(.secondary)

                if model.showRecordingTip {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "video.badge.checkmark").foregroundStyle(.tint)
                        Text("For recordings, capture your browser or app window—not the floating prompter.")
                            .font(.subheadline)
                        Spacer()
                        Button { model.showRecordingTip = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss recording tip")
                    }
                    .padding(12).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.studioAppearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .restoreEchoPromptWorkspace)) { _ in
            model.restoreWorkspace()
        }
    }
}

struct SavedScriptsPopover: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved scripts", systemImage: "bookmark.fill").font(.headline)
                Spacer()
                Button("Reveal in Finder") { model.revealScriptLibrary() }.buttonStyle(.bordered)
            }
            Text("Saved as .txt files in Documents/EchoPrompt Scripts")
                .font(.caption).foregroundStyle(.secondary)
            if model.history.isEmpty {
                Text("Scripts appear here after you start EchoPrompt.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.history) { item in
                            HStack(spacing: 10) {
                                Button { model.loadHistory(item) } label: { Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                    .buttonStyle(.plain)
                                Button { model.deleteHistory(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete saved script")
                            }.padding(.vertical, 8)
                            if item.id != model.history.last?.id { Divider() }
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }.padding(16).frame(width: 330)
    }
}

struct EditorCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ControlLabel: View {
    let title: String
    let value: Double
    let suffix: String
    var body: some View {
        Text("\(title): \(suffix == "×" ? String(format: "%.2f", value) : String(Int(value)))\(suffix)")
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }
}

/// Explicitly uses an NSSlider without tick marks. The default stepped SwiftUI
/// slider introduces a dotted tick row that distracts from the reading controls.
struct SmoothSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.controlSize = .large
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: SmoothSlider
        init(_ parent: SmoothSlider) { self.parent = parent }
        @objc func valueChanged(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

struct PromptView: View {
    @ObservedObject var model: PrompterModel
    @State private var isPlaying = false
    @State private var showTextAppearance = false
    @State private var offset: CGFloat = 0
    @State private var lastTick = Date()
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let baseSpeed: Double = 24
    private let speedSteps: [Double] = [0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

    private var playbackRate: Double { model.speed / baseSpeed }
    private var playbackRateLabel: String { String(format: "%.2f×", playbackRate) }

    private func changeSpeed(forward: Bool) {
        let current = playbackRate
        if forward {
            let next = speedSteps.first(where: { $0 > current + 0.01 }) ?? speedSteps.last!
            model.speed = next * baseSpeed
        } else {
            let previous = speedSteps.last(where: { $0 < current - 0.01 }) ?? speedSteps.first!
            model.speed = previous * baseSpeed
        }
    }

    var body: some View {
        ZStack {
            model.promptBackground.opacity(model.opacity).ignoresSafeArea()
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(model.script.isEmpty ? "Paste a script in the editor." : model.script)
                            .font(.system(size: model.fontSize, weight: .medium))
                            .foregroundStyle(model.promptText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(model.fontSize * (model.lineSpacing - 1))
                            .padding(.horizontal, 56)
                            .padding(.vertical, proxy.size.height * 0.42)
                            .scaleEffect(x: model.mirrorText ? -1 : 1, y: 1)
                            .offset(y: -offset)
                            .id("script")
                    }
                    // The script is moved by the prompter, not by incidental
                    // trackpad gestures over the control dock.
                    .scrollDisabled(true)
                }
            }
            .clipped()

            VStack(spacing: 0) {
                HStack {
                    Button { model.closePrompter() } label: {
                        Label("Edit script", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .help("Return to the EchoPrompt Script Studio")
                    Spacer()
                    VStack(spacing: 2) {
                        Text(model.controlMode.name.uppercased())
                        Text(isPlaying ? "SCROLLING" : "PAUSED")
                    }
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button { offset = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.96))
                Spacer()
                VStack(spacing: 10) {
                    GeometryReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                PromptControlButton(title: "Slower", detail: "− speed", icon: "tortoise") { changeSpeed(forward: false) }
                                PromptControlButton(title: isPlaying ? "Pause" : "Play", detail: playbackRateLabel, icon: isPlaying ? "pause.fill" : "play.fill", prominent: true) { isPlaying.toggle() }
                                    .keyboardShortcut(.space, modifiers: [])
                                PromptControlButton(title: "Faster", detail: "+ speed", icon: "hare") { changeSpeed(forward: true) }
                                PromptControlButton(title: "Text", detail: "Aa", icon: "textformat") { showTextAppearance.toggle() }
                                    .popover(isPresented: $showTextAppearance, arrowEdge: .bottom) {
                                        PromptAppearanceInspector(model: model)
                                    }
                                Toggle("Mirror text", isOn: $model.mirrorText)
                                    .toggleStyle(.switch)
                                    .foregroundStyle(.white)
                            }
                            .frame(minWidth: proxy.size.width, alignment: .center)
                            .padding(.horizontal, 2)
                        }
                    }
                    .frame(height: 58)
                    Text("Space: play or pause   •   Esc: close   •   Reading pace: \(playbackRateLabel)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
                .shadow(color: .black.opacity(0.7), radius: 14, y: -5)
            }
        }
        .onReceive(timer) { now in
            let elapsed = now.timeIntervalSince(lastTick)
            lastTick = now
            if isPlaying { offset += CGFloat(model.speed * elapsed) }
        }
        .onExitCommand { model.closePrompter() }
    }
}

/// A small, temporary live inspector. It is anchored to the Text control rather
/// than becoming another opaque layer across the reading surface.
struct PromptAppearanceInspector: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text size \(Int(model.fontSize)) pt").font(.caption.weight(.semibold))
                SmoothSlider(value: $model.fontSize, range: 24...110)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Line spacing \(String(format: "%.2f", model.lineSpacing))×").font(.caption.weight(.semibold))
                SmoothSlider(value: $model.lineSpacing, range: 0.9...2.0)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct PromptControlButton: View {
    let title: String
    let detail: String
    let icon: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.body.weight(.bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.bold))
                    Text(detail).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(prominent ? Color.accentColor : Color(red: 0.22, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        Form {
            Slider(value: $model.opacity, in: 0.25...1) { Text("Prompt background opacity") }
            Toggle("Show recording-safe guidance", isOn: $model.showRecordingTip)
        }.padding().frame(width: 390)
    }
}
