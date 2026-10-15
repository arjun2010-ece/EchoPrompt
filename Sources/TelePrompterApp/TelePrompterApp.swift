import SwiftUI
import AppKit
import Combine

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
        NotificationCenter.default.post(name: .restoreEchoPromptWorkspace, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

struct SavedScript: Codable, Identifiable, Equatable {
    var id: UUID
    var body: String
    var savedAt: Date
    init(body: String, savedAt: Date = .now) { self.id = UUID(); self.body = body; self.savedAt = savedAt }
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

@MainActor
final class PrompterModel: ObservableObject {
    @Published var script = "Welcome to EchoPrompt.\n\nPaste your script here, then start EchoPrompt when you are ready."
    @Published var fontSize: Double = 50
    @Published var speed: Double = 24
    @Published var opacity: Double = 0.92
    @Published var mirrorText = false
    /// Normal scrolling is deliberately the default. Voice mode is opt-in.
    @Published var voiceControlled = false
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

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey), let items = try? JSONDecoder().decode([SavedScript].self, from: data) { history = items }
    }

    func saveHistoryNow() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let activeHistoryID, let index = history.firstIndex(where: { $0.id == activeHistoryID }) {
            // Preserve the loaded script's identity instead of creating a duplicate.
            history[index].body = script
            history[index].savedAt = .now
        } else {
            history.removeAll { $0.body == script }
            let saved = SavedScript(body: script)
            history.insert(saved, at: 0)
            activeHistoryID = saved.id
        }
        history = Array(history.prefix(20))
        persistHistory()
    }

    func loadHistory(_ item: SavedScript) { activeHistoryID = item.id; script = item.body }
    func deleteHistory(_ item: SavedScript) {
        history.removeAll { $0.id == item.id }
        if activeHistoryID == item.id { activeHistoryID = nil }
        persistHistory()
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
                        Slider(value: $model.fontSize, in: 24...110, step: 1)
                        ControlLabel(title: "Scroll speed", value: model.speed, suffix: " px/s")
                        Slider(value: $model.speed, in: 5...100, step: 1)
                    }
                    EditorCard(title: "How you control it", icon: "hand.tap.fill") {
                        HStack(spacing: 9) {
                            Text("Normal").fontWeight(model.voiceControlled ? .regular : .semibold)
                            Toggle("Voice-controlled", isOn: $model.voiceControlled).labelsHidden().toggleStyle(.switch).accessibilityLabel("Voice-controlled mode")
                            Text("Voice").fontWeight(model.voiceControlled ? .semibold : .regular)
                        }
                        Text(model.voiceControlled ? "Voice mode selected" : "Manual controls selected")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Toggle("Click through prompt", isOn: $model.clickThroughPresentation)
                            .font(.subheadline)
                        Text("Useful while working in VS Code. Use the Dock to return to EchoPrompt and turn it off.")
                            .font(.caption).foregroundStyle(.secondary)
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
            Label("Saved scripts", systemImage: "bookmark.fill").font(.headline)
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
        Text("\(title): \(Int(value))\(suffix)")
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }
}

struct PromptView: View {
    @ObservedObject var model: PrompterModel
    @State private var isPlaying = false
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
                            .lineSpacing(model.fontSize * 0.28)
                            .padding(.horizontal, 56)
                            .padding(.vertical, proxy.size.height * 0.42)
                            .scaleEffect(x: model.mirrorText ? -1 : 1, y: 1)
                            .offset(y: -offset)
                            .id("script")
                    }
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
                        Text(model.voiceControlled ? "VOICE-CONTROLLED" : "NORMAL TELEPROMPTER")
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
                    HStack(spacing: 12) {
                        PromptControlButton(title: "Slower", detail: "− speed", icon: "tortoise") { changeSpeed(forward: false) }
                        PromptControlButton(title: isPlaying ? "Pause" : "Play", detail: playbackRateLabel, icon: isPlaying ? "pause.fill" : "play.fill", prominent: true) { isPlaying.toggle() }
                            .keyboardShortcut(.space, modifiers: [])
                        PromptControlButton(title: "Faster", detail: "+ speed", icon: "hare") { changeSpeed(forward: true) }
                        Toggle("Mirror text", isOn: $model.mirrorText)
                            .toggleStyle(.switch)
                            .foregroundStyle(.white)
                    }
                    Text("Space: play or pause   •   Esc: close   •   Reading pace: \(playbackRateLabel)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.98))
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
