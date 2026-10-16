# Spec: Capture-invisible prompter & flexible placement

Status: Draft, ready for implementation
Target: EchoPrompt macOS app (`Sources/TelePrompterApp/TelePrompterApp.swift`), macOS 13+
Date: 2026-10-16

## 1. Summary

Two features for the floating prompt panel:

1. **Hidden from capture.** Viewers of Mac screen shares (Zoom, Meet, Teams, FaceTime, Slack huddles) and of screen recordings (QuickTime, ⇧⌘5, OBS, Loom) shouldn't see the prompter, while the presenter still can.
2. **Placement.** The presenter can put the prompter in one of three places:
   - **Notch:** tucked under the MacBook camera notch. On a screen without a notch it docks at the top center instead.
   - **Corner:** any of the four screen corners.
   - **Floating:** a free window that can be moved and resized anywhere, which is how the app behaves today.

Both features apply only to the prompt `NSPanel`. Script Studio doesn't change, apart from new settings.

## 2. Goals and non-goals

### Goals
- G1. Capture hiding is **on by default**, and each presentation can turn it off with one toggle.
- G2. Hiding covers every window the prompter shows: the panel, its popovers, and the hover controls.
- G3. The presenter picks a placement in Script Studio and can switch it live from the prompter without losing their reading position.
- G4. Each placement is remembered across launches. Floating mode also remembers its frame for each display.
- G5. Placement handles multiple displays, display hot-plugging, resolution changes, and Dock or menu-bar changes.
- G6. All three control modes (Normal, Voice, Recorded audio) work the same in every placement.

### Non-goals
- Hiding from a physical camera, or from capture tools that read the framebuffer directly (HDMI capture cards, AirPlay mirroring). These can't be controlled from inside the app.
- Hiding the Script Studio window. Possible later, see §9.
- Global hotkeys that work while another app is focused. Proposed as a follow-up in §9.
- Windows or iPad versions.

## 3. Platform constraints (read before implementing)

### 3.1 Capture invisibility
- The only public lever is `NSWindow.sharingType = .none`. It tells the WindowServer to leave the window out of captures made by **other** processes.
- **Legacy capture APIs** (`CGWindowListCreateImage`, `CGDisplayStream`, the older Zoom and Teams capture paths) reliably honor it.
- **ScreenCaptureKit** (SCK) honors it inconsistently. There are reports that the window is excluded when a stream starts but appears after the content filter is rebuilt, and anecdotal reports that macOS 15 changed the behavior. The capturing app owns its `SCContentFilter`, so EchoPrompt can't force the exclusion.
- **Consequence:** the feature is **best-effort**. The UI must not promise "100% invisible". Proposed copy: *"Hide from screen sharing & recordings. Works with most apps. Run a test recording before going live."*
- `sharingType` is set per window. Popovers (`NSPopover`), tooltip windows, sheets and menus create their **own** windows and do **not** inherit it (see §5.3).
- A hidden window also disappears from the presenter's own screenshots (⇧⌘3/4/5). This is expected, and the help text should mention it.

### 3.2 Notch geometry (macOS 12+ APIs, available on our 13+ floor)
- Notch present: `screen.safeAreaInsets.top > 0`.
- Notch rectangle: `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are the usable strips on either side of the notch. The notch spans `x = leftArea.maxX … rightArea.minX`, and its height equals `safeAreaInsets.top`.
- Pixels inside the notch rectangle are physically missing. Content has to start below `safeAreaInsets.top`.
- To sit over the menu bar, the window needs a level above the main menu, `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)`, which is effectively `.statusBar`. It also has to override `constrainFrameRect(_:to:)`, otherwise AppKit pushes the window below the menu bar.

### 3.3 Existing invariants to preserve (from CLAUDE.md)
- The panel is created **once** and reused. `presentationSessionID` remains the only reset signal for `PromptView` state. Changing placement **must not** recreate the panel or the `NSHostingView`, because that would reset the reading position.
- Normal mode must never touch `AVAudioEngine.inputNode`.
- Don't restore the Studio while the prompt panel is visible. `AppDelegate.applicationShouldHandleReopen` finds the panel with `$0 is NSPanel`, and a subclass still matches.

## 4. Data model

Add to `PrompterModel`. Each property is `@Published` and persisted in `UserDefaults` with keys under the `EchoPrompt.` prefix.

```swift
enum PromptPlacement: String, CaseIterable, Identifiable, Codable {
    case notch, corner, floating
    var id: String { rawValue }
    var name: String { /* "Notch", "Corner", "Floating" */ }
}

enum PromptCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum PromptLayoutStyle { case full, compact, notch }   // derived, not persisted
```

| Property | Type | Default | UserDefaults key |
|---|---|---|---|
| `hideFromScreenCapture` | `Bool` | `true` | `EchoPrompt.hideFromCapture.v1` |
| `placement` | `PromptPlacement` | `.floating` (current behavior) | `EchoPrompt.placement.v1` |
| `corner` | `PromptCorner` | `.topRight` | `EchoPrompt.corner.v1` |
| `cornerSize` | `CGSize` | `420 × 240` | `EchoPrompt.cornerSize.v1` |
| `notchSize` | `CGSize` (width/height of the expanded body below the notch) | `560 × 150` | `EchoPrompt.notchSize.v1` |
| `floatingFrames` | `[String: CGRect]` keyed by display identifier | empty, falling back to today's 900×360 frame 40 pt below the top center | `EchoPrompt.floatingFrames.v1` |
| `targetDisplayID` | `String?` (see §6.5) | `nil`, meaning the screen of the Studio window, then `NSScreen.main` | `EchoPrompt.targetDisplay.v1` |

Derived: `layoutStyle` is `.notch` for notch placement, `.compact` for corner placement, `.full` for floating placement. One exception: floating at a width under 560 pt or a height under 260 pt uses `.compact` (see §7.2).

Persistence is set in `didSet`. The existing settings (`fontSize`, `speed` and so on) aren't persisted today. That's fine, and changing it is out of scope.

## 5. Feature A: Hidden from capture

### 5.1 Behavior
- When `hideFromScreenCapture == true`, every prompter-owned window has `sharingType = .none`. When it's false, they use `.readOnly`, the AppKit default.
- The toggle takes effect **immediately**, including while presenting (`didSet` → `applyCaptureVisibility()`).
- The Studio window's `sharingType` is never changed.

### 5.2 Implementation
- `PrompterModel.applyCaptureVisibility()` sets `panel?.sharingType` and records the current value for child windows.
- Call it in `openPrompter()` both when the panel is created and when it's reused, so the value is right before `makeKeyAndOrderFront`. Setting it before the first order-front matters: some capture tools snapshot the window list when a stream starts.
- Recommended: also call it from `windowDidChangeScreen` (`NSWindowDelegate`) as a cheap defensive step.

### 5.3 Child windows
Add a small `NSViewRepresentable`, `CaptureVisibilityProbe`, whose `NSView` subclass overrides `viewDidMoveToWindow()` to set `window?.sharingType` from the model. Attach it as a zero-size `.background(...)` to:
- the content of `PromptAppearanceInspector`, which runs in an `NSPopover` window;
- any new placement-menu popover (§7.4).

`.help(...)` tooltips run in system tooltip windows, which the app can't control. In `.compact` and `.notch` layouts, **don't** use `.help`. Use `accessibilityLabel` only. In `.full` layout, existing tooltips may stay, and the resulting brief leak while the pointer is over a button is acceptable.

### 5.4 UI
- **Studio → Presentation card:** a new switch above "Click through prompt".
  - Title: "Hide from screen sharing"
  - Subtitle: "Viewers and recordings won't see the prompter in most apps."
- **Settings window:** the same toggle, plus a line explaining that it also hides the prompter from the presenter's own screenshots.
- **Recording tip banner:** the current text is "capture your browser or app window—not the floating prompter". Make it conditional:
  - Hiding on: "EchoPrompt is hidden from screen sharing. Do a 10-second test recording in your meeting app before going live."
  - Hiding off: keep the current text.
- **Prompter:** a small `eye.slash` badge in the header (full layout) or the hover bar (compact and notch layouts) shows that hiding is active. Clicking it toggles the setting.

### 5.5 Verification matrix (manual, required before release)
Run on macOS 13, 14, 15 and the current release, with a notched MacBook plus an external display. Record ✅ (hidden), ❌ (visible) or ⚠️ (intermittent) in this table, and keep it in the spec:

| Capture tool | Full-screen share | Window share (other app) | Notes |
|---|---|---|---|
| ⇧⌘5 / QuickTime screen recording | | n/a | |
| Zoom | | | also toggle "optimize for video" |
| Google Meet (Chrome, Safari) | | | |
| Microsoft Teams | | | |
| FaceTime / SharePlay screen share | | | |
| Slack huddle | | | |
| OBS (macOS Screen Capture / SCK source) | | | restart the source to test filter rebuild |
| Loom | | | |

If a major tool fails consistently on a given OS, the toggle subtitle should name it, for example "Not supported by X on macOS 15". Don't hide the failure.

## 6. Feature B: Placement

### 6.1 Panel construction (replaces the current titled utility panel)
Replace the `NSPanel(... [.titled, .closable, .resizable, .utilityWindow])` setup with a subclass that is **created once** and configured per placement:

```swift
final class PromptPanel: NSPanel {
    var allowsMenuBarOverlap = false
    override var canBecomeKey: Bool { true }     // borderless panels return false by default
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? r : super.constrainFrameRect(r, to: s)
    }
}
```

- Style mask: `[.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView]`, set at init. Don't toggle `.nonactivatingPanel` after init, because it's unreliable.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow` set per placement. SwiftUI draws the rounded-rectangle chrome.
- `isReleasedWhenClosed = false`, `hidesOnDeactivate = false`.
- Collection behavior: keep `[.canJoinAllSpaces, .fullScreenAuxiliary]` and add `.stationary` and `.ignoresCycle`.
- Being non-activating means clicking the prompter during a Zoom call doesn't pull EchoPrompt or Studio forward. Because `canBecomeKey` is true, the Space and Esc shortcuts still work while the panel is key.
- The titlebar close button goes away. Closing happens through "Edit script", Esc, or the new ✕ in compact layouts. All of them go through `closePrompter()`, which also fixes today's path where the red close button skips `restoreWorkspace()`.

### 6.2 Applying a placement
Add `PrompterModel.applyPlacement(animated: Bool)`. It's called from `openPrompter()` (unanimated), from `placement`, `corner` or `targetDisplayID` `didSet` while the panel is visible (animated, 0.2 s via `NSAnimationContext` / `animator().setFrame`), and from screen-change notifications (§6.5). For each placement it sets:

| | Notch | Corner | Floating |
|---|---|---|---|
| `level` | above main menu (§3.2) | `.floating` | `.floating` |
| `allowsMenuBarOverlap` | `true` | `false` | `false` |
| `isMovableByWindowBackground` | `false` | `true` (drag ends in a snap, §6.3) | `true` |
| Resizable | height only, via a bottom drag handle | yes, opposite corner stays anchored | yes |
| `hasShadow` | `false`, so it merges with the notch | `true` | `true` |
| Frame | §6.4 | §6.3 | restored from `floatingFrames[display]` or the default, then clamped to `visibleFrame` |

`applyPlacement` must not touch `contentView`. `PromptView` reads `model.layoutStyle` and re-lays itself out, so its `@State` (offset, active word, playback) survives.

### 6.3 Corner placement
- Frame: `cornerSize` inset **16 pt** from the matching corner of `screen.visibleFrame`, which respects the menu bar and Dock.
- Resizing keeps the anchored corner fixed and saves the result to `cornerSize`. Minimum 300 × 160, maximum 60% of `visibleFrame` on each axis.
- **Drag-to-snap:** the user can drag the panel. On mouse-up (`windowDidMove` plus a short debounce, or a `windowDidEndLiveResize`-style check), the panel snaps to the **nearest** corner and updates `corner`. This is how a user moves between corners without opening Studio.

### 6.4 Notch placement
Geometry on a notched screen:
- `notchRect` is computed as in §3.2.
- Panel width is `max(notchSize.width, notchRect.width + 2 × 60)`, centered on `notchRect.midX`.
- The panel's top edge sits at `screen.frame.maxY`, the physical top. Panel height is `safeAreaInsets.top + notchSize.height`.
- The SwiftUI surface is pure black and shaped like the notch: square top corners and 18 pt bottom corners, flared slightly like the hardware notch. The body extends downward and reads as one surface with the notch.
- Script text starts at `y = safeAreaInsets.top + 6`, so the current line sits right under the camera, the best eye line.

On a screen without a notch (an external display or an older Mac), it falls back to **top-center dock**. The same layout and width apply, the top edge sits at `visibleFrame.maxY`, which is under the menu bar, and the top inset is 0. Studio's placement picker reads **"Notch / Top center"** with the help text "Docks at top center on displays without a notch."

Notch-mode surface rules:
- The background is always black at opacity 1.0, whatever `promptTheme` and `opacity` say. Anything else breaks the notch illusion. Text uses `promptTheme.text` if that has a contrast ratio of at least 4.5:1 on black, otherwise white.
- Height is adjustable with a bottom drag handle, from 80 to 400 pt, and saved to `notchSize.height`. Width presets come from the hover bar: S 440, M 560, L 760.
- If the menu bar is set to auto-hide, the layout is the same. The panel covers the menu-bar region, and that is intended.
- In a full-screen app Space, `.fullScreenAuxiliary` plus the high level keeps the panel visible. Confirm this in the verification matrix.

### 6.5 Display selection and screen changes
- **Display identity:** store `CGDirectDisplayID` together with `NSScreen.localizedName` as `"\(id)|\(name)"`. Resolve by ID first, then by name, then fall back to the screen of the Studio window, then `NSScreen.main`. Display IDs can change after a reboot or a dock reconnect.
- The **target display** defaults to the screen the Studio window was on when the user clicked Start. A "Display" picker in Studio appears **only** when `NSScreen.screens.count > 1`.
- Observe `NSApplication.didChangeScreenParametersNotification`, plus `NSWorkspace.activeSpaceDidChangeNotification` for notch reassertion. On each one, re-resolve the display and call `applyPlacement(animated: false)`. If the target display has disappeared, move to the main screen and keep the placement. Notch falls back to top center automatically.
- Floating frames are saved on `windowDidMove` and `windowDidEndLiveResize`, keyed by display identity, and clamped so at least 80 × 40 pt stays on-screen when restored.

## 7. PromptView layout changes

### 7.1 `.full` (floating, large enough)
The current layout stays: the header with Edit script, mode/status and restart, the script area, and the bottom control bar with footer. Two additions:
- A drag region. The header acts as the drag handle, which already works through `isMovableByWindowBackground`. Make sure buttons inside it still receive clicks.
- The capture badge (§5.4) and a placement menu button (§7.4) in the header, to the left of restart.
- Rounded corners (12 pt) and a 1 pt hairline border drawn in SwiftUI, because the system frame is gone.

### 7.2 `.compact` (corner, or a small floating window)
- The header and the bottom control bar are hidden. The script area fills the panel.
- A **hover bar** fades in (0.15 s) along the bottom edge on `onHover`, and fades out 1.5 s after the pointer leaves. It contains: play/pause (or start voice), slower, faster (disabled outside Normal, as today), restart, Text (Aa popover with the probe from §5.3), placement menu, capture badge, and ✕ (calls `closePrompter()`).
- Status (mode, voice status, "Heard: …") is a single caption line in the hover bar. Errors or warnings, such as voice not listening or audio not ready, show a persistent 6 pt orange dot in the top-right corner even when the bar is hidden.
- The keyboard works as before: Space plays or pauses, Esc closes.
- Font size follows `fontSize` but is clamped to `min(fontSize, panelHeight / 3)` so at least about 2 lines fit.

### 7.3 `.notch`
- Same as compact, with these differences: the hover bar appears **below** the panel's bottom edge and reveals on hover over the panel, and the text is centered with line count driven by height.
- The current reading line sits in the upper part of the body in Voice and Recorded modes. In notch layout the scroll anchor is `UnitPoint(x: 0.5, y: 0.4)`, which keeps the live word near the camera with room above it.
- In Normal mode, the first line starts about 35% of the way down the body, so each line stays readable for a moment before it scrolls out.
- Notch and compact layouts fade text out over the top 22% of the script area instead of cutting it off.

### 7.4 Placement menu (in the prompter)
A `Menu` (not a popover, to avoid another window) with the following items:
- Notch / Top center, Corner ▸ (four corners), Floating.
- A Display ▸ submenu when more than one display is connected.
- A "Hide from screen sharing" checkmark item.

Selecting an item updates the model, and `applyPlacement(animated: true)` runs.

`NSMenu` windows are short-lived, and the system draws them. They may appear in captures while open. That's acceptable, and the spec records it here.

### 7.5 Click-through interaction
- With `clickThroughPresentation` on, the hover bar can't be reached by mouse. Show a one-time hint the first time click-through is on in compact or notch layout: "Click-through is on. Use Space / Esc, or ⇧⌘E to return."
- In notch placement, click-through is **recommended** because the panel covers menu-bar items. If click-through is off, show this note under the notch option in Studio: "Covers part of the menu bar while presenting."

## 8. Studio UI changes (EditorView)

Presentation card, in order:
1. **Placement:** a segmented `Picker` with "Notch", "Corner" and "Floating", each with an SF Symbol (`macbook`, `rectangle.inset.topright.filled`, `macwindow`).
   - With Corner selected, a 2×2 mini grid of corner buttons appears.
   - With Notch selected and no notch on the target display, an inline caption reads "No notch on this display. Will dock at top center."
2. **Display:** shown only on multi-display setups.
3. **Hide from screen sharing:** the toggle from §5.4.
4. **Click through prompt:** existing.
5. The existing "Return with Edit script or ⇧⌘E" caption.

The ⌘↩ hint text changes from "…in a focused floating window" to "…in your chosen placement".

## 9. Follow-ups (out of scope, noted for later)
- **Global hotkeys** via Carbon `RegisterEventHotKey`, which needs no Accessibility permission. Play/pause and close would work while Zoom is focused. This matters most for notch placement with click-through on.
- **Hide Script Studio from capture** as a separate toggle.
- **Hover-to-pause:** pause Normal scrolling while the pointer is over the prompter.
- **Snap zones in floating mode:** dragging near a screen edge or corner offers a corner or notch placement.

## 10. Acceptance criteria

**Capture**
- [ ] AC1. With the toggle on, a ⇧⌘5 full-screen recording on macOS 13 and 14 doesn't show the prompter or its Aa popover.
- [ ] AC2. The verification matrix (§5.5) is filled in for all listed tools on at least macOS 14 and the current release.
- [ ] AC3. Switching the toggle off mid-presentation makes the prompter appear in an ongoing ⇧⌘5 recording, and switching it back on hides it again, with no reopen needed.
- [ ] AC4. The Studio window is always visible in captures.

**Placement**
- [ ] AC5. On a notched MacBook, Notch placement puts a black surface flush with the notch, with no visible gap or seam at 100% and scaled resolutions, and the first text line fully below the notch.
- [ ] AC6. On an external display without a notch, Notch placement docks at top center under the menu bar.
- [ ] AC7. Each of the four corners places the panel 16 pt inside `visibleFrame`, without overlapping the Dock, in every Dock position (bottom, left, right, auto-hide).
- [ ] AC8. Dragging a corner-placed panel and releasing it snaps it to the nearest corner and persists that corner.
- [ ] AC9. A floating frame survives app relaunch, and is restored per display.
- [ ] AC10. Changing placement while Normal mode is scrolling, or while Voice mode is following, keeps the scroll position, highlighted word and playback state. No reset happens unless the user restarts or reopens.
- [ ] AC11. Unplugging the display the prompter is on moves it to the remaining display in the same placement within 1 s.
- [ ] AC12. Space and Esc work in all three placements right after opening, without clicking the panel first.
- [ ] AC13. A Dock-icon click while the prompter is visible in any placement doesn't restore Studio. The existing `AppDelegate` behavior is kept.
- [ ] AC14. Under `swift run`, Normal mode works in all placements, and nothing touches `AVAudioEngine.inputNode`.

## 11. Implementation plan (suggested order)
1. Add `PromptPanel` and switch to borderless with SwiftUI chrome, with the floating placement only. Get parity with today's behavior, including resizing.
2. Capture hiding: model, `applyCaptureVisibility`, `CaptureVisibilityProbe`, Studio and Settings toggles, conditional tip banner. Start the verification matrix.
3. Model enums, persistence and `applyPlacement`. Corner placement with snapping.
4. `layoutStyle` with compact `PromptView` and the hover bar.
5. Notch geometry, notch layout, top-center fallback.
6. Multi-display support and screen-change handling.
7. Placement menu in the prompter, then the Studio UI polish.
8. Fill in the full verification matrix and walk through the acceptance criteria with `./build-app.sh` (Voice and Recorded modes need the bundle).

Keep everything in `TelePrompterApp.swift`, matching the single-file convention. Put each new type under a `// MARK:` section.

## 12. Implementation notes (2026-10-16)

- The open questions were resolved with their recommendations. Floating stays the default, and a dismissible "Try Notch placement" tip appears in Studio on notched Macs. Hiding defaults on, with an explanation in Settings. macOS 13 remains the floor.
- **Deviation from §7.3:** in notch layout the hover bar is overlaid inside the bottom of the notch body, not drawn below the panel's edge. Drawing it below would need a transparent strip that captures mouse events over other apps.
- Corner and floating resizing use native edge resizing on the borderless `.resizable` panel. There's no SwiftUI grip. If edge resizing turns out unreliable on some OS version, add a grip.
- Space and Esc are bound to hidden, always-present buttons, so they work in every layout. `onExitCommand` is kept as a fallback.
- The verification matrix (§5.5) and the acceptance criteria (§10) still need a manual pass.

## 13. Open questions (resolved, see §12)
1. Should **Notch** become the default placement on notched Macs for new users, or should Floating stay the default so existing users see no change? Recommendation: keep Floating, and show a one-time "Try Notch placement" tip.
2. Should hide-from-capture default **on**? It hides the prompter from the presenter's own screenshots, which can confuse people. Recommendation: on, with an explanation in Settings.
3. Acceptable minimum macOS for notch mode is 13, since the APIs exist from 12. Is there anything below 13 to consider? No, because the app's floor is already 13.
