# Plan: a desktop experience that feels obvious (macOS + Windows)

Status: v3 — implemented on macOS and Windows (see §8 for what shipped and what was deferred)
Date: 2026-10-18
Scope: the Flutter app in `app/` on **macOS and Windows** (R1 in `cross-platform-plan.md`). Mobile (iOS, iPadOS, Android) gets its own UX plan later.

---

## 1. Honest review of the current UI

Short version: **everything works, but the UI shows how the app is built, not what the user is trying to do.** Every setting sits in one flat `Wrap` of sliders, switches and dropdowns (`studio_screen.dart` → `_SettingsPanel`). You can't see the effect of most of them until you press *Start teleprompter*, and once the prompter is open you can't leave the app without going back first.

### 1.1 What the user reported, and what the code shows

| # | Report | What's actually going on | Verdict |
|---|---|---|---|
| 1 | "Why is there an eye icon and a *Notch / Top center* icon? The demo didn't have them." | Both arrived with commit `1a85ebe` (the invisibility + placement spec), after the demo build you used. The Flutter port copies them as-is. The eye is a **one-click toggle that exposes the prompter to viewers** (`_captureBadge`), and the placement menu uses an unclear icon (`Icons.dashboard_customize`). | **Valid.** An unclear icon that can leak your script on a live call doesn't belong in a toolbar you use while presenting. Placement should stay but be easy to understand (§3.3). |
| 2 | "No exit or close from the teleprompter screen." | The prompter only offers *Edit script* (full layout) or `×` = "close prompter and edit script" (hover bar). The window is borderless and top-most with no title bar, so you can't see the system close button or menu. | **Valid, and the most serious problem.** Users must always be able to leave the app from wherever they are (§3.4). |
| 3 | "The Spacing slider doesn't change anything on the Studio screen, only on the prompter." | Two problems. **(a) No preview:** the Studio editor is a plain `TextField` that never uses font size, spacing, theme or mirror. **(b) A real bug:** the Studio slider's range is `0…40` (`studio_screen.dart`), but `lineSpacing` is a line-height multiplier from `0.9…2.0` (default `1.28`; the prompter's own slider and the Swift POC both use `0.9…2.0`). Dragging it in Studio sets values like `25×`, so the prompter text spreads out absurdly. The Speed slider has the same issue (`5…300` in Studio, `5…100` in the POC). | **Valid, plus a bug.** Fix the ranges now. The real fix is a live preview (§3.1). |
| 4 | "Rotate 180° doesn't make sense on macOS." | `rotated` was added for teleprompter glass rigs. On a desktop, the OS already rotates displays (System Settings → Displays → Rotation; Windows Display settings → Orientation), and a rotated **overlay** over other apps is never what you want. | **Valid.** Remove it on desktop. Keep it for mobile Read mode (iPad on a glass rig). |
| 5 | "Click-through isn't needed? Same for Hide from screen capture." | **Click-through:** has a real use (a prompter over Zoom/PowerPoint controls in a corner that you still need to click), but as a hidden switch in Studio it causes "why can't I click my prompter?" moments. **Hide from capture:** this *is* the product (R1). It must stay on. It's the *control* that should go. | **Partly.** Capture hiding stays, with its switch in Preferences. Click-through was tried as a Lock button and then removed (§3.5). |

### 1.2 Other problems found in the code

- **Raw enum names in the UI.** Dropdowns show `e.name`: `recordedAudio`, `topLeft`, `floating`, `dark`.
- **Settings are mixed together.** Crash reporting sits between *Mirror* and *Rotate 180°*. *Studio appearance* (the app's own theme) sits next to *Prompt theme*.
- **Two places to change the same thing, with different ranges.** Studio sliders and the prompter's *Text* popover both change font size and spacing, but with different ranges and labels (`Spacing` vs `Line spacing 1.28×`).
- **Saved-scripts list shows a raw timestamp** (`2026-10-18 14:03:22`) instead of "Today, 14:03".
- **No word count / read-time estimate** (the POC shows a word count).
- **No keyboard shortcut for Start** (the POC uses ⌘↩).
- **Mirror is a big switch on the prompter control bar.** You set it once for a glass rig, not while reading.
- **The prompter header has 3 small unlabelled icons** (eye, placement, restart). Restart sits next to the capture toggle, so they're easy to mis-click.
- **The overlay can't be controlled from another app.** When you're in Zoom or Keynote, the prompter has no keyboard focus, so Space/Esc don't reach it. You have to move the mouse to it.

### 1.3 Overall verdict

Not yet intuitive. The underlying engine (modes, matching, overlay, capture hiding) is solid. The problems are information architecture and feedback:
1. **No live preview:** you change settings in one place and only see the result in another.
2. **No obvious way out:** the overlay has no close/quit.
3. **Too many settings at the same level:** engineering toggles and core choices are mixed together.
4. **Unclear controls on the overlay**, including one that can leak your script.

---

## 2. Design principles (what "great" means here)

1. **What you see is what you'll get.** Any change to how the prompter *looks* is visible immediately, on the screen you made it on. No "start it to find out".
2. **One decision at a time.** Studio asks three questions in order: *What will I read?* (script) → *How should it follow me?* (mode) → *Where should it sit?* (position). Everything else is in a preferences window.
3. **You can always leave.** Close and Quit are reachable from the overlay, from the menu bar / system tray, and from the keyboard, on both OSes.
4. **Safe by default.** Hidden from screen sharing is always on. Nothing on the overlay can accidentally reveal it.
5. **Controllable without focus.** While you present in another app, global shortcuts drive the prompter.
6. **Show only what this platform supports.** No Rotate on desktop, no "Notch" wording on Windows or on Macs without a notch (already a rule in `cross-platform-plan.md` §4).
7. **Same controls, same order, in every layout.** Full, compact and notch layouts share one control set; they differ only in density.

---

## 3. The target experience

### 3.1 Script Studio: editor + live preview, one screen

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ EchoPrompt                                   [Import] [Export] [Folder]  ⚙   │
├───────────────┬───────────────────────────────┬──────────────────────────────┤
│ SCRIPTS    ＋ │ Your script        412 words · ~3 min                         │
│ ───────────── │ ┌───────────────────────────┐ │  LIVE PREVIEW                │
│ ● Product     │ │ Welcome everyone. Today   │ │ ┌──────────────────────────┐ │
│   launch      │ │ I want to walk you        │ │ │  Welcome everyone.       │ │
│   Today 14:03 │ │ through…                  │ │ │  Today I want to walk    │ │
│               │ │                           │ │ │  you through…            │ │
│   Weekly      │ │                           │ │ └──────────────────────────┘ │
│   update      │ │                           │ │  (exact overlay: theme, size,│
│   Yesterday   │ │                           │ │   spacing, opacity, mirror,  │
│               │ │                           │ │   shape of chosen position)  │
│               │ └───────────────────────────┘ │                              │
│               │                               │  FOLLOW   [Normal|Voice|Audio]│
│               │                               │  POSITION [▣ Notch][◰ Corner]│
│               │                               │           [▢ Floating]       │
│               │                               │  TEXT  Size ──●──  48 pt     │
│               │                               │        Spacing ─●─  1.3×     │
│               │                               │        Theme ◐ ◑ ●            │
│               │                               │                              │
│               │                               │      [ ▶ Start  ⌘↩ ]         │
└───────────────┴───────────────────────────────┴──────────────────────────────┘
```

- **Live preview pane (the key change).** It renders the **real `PromptSurface` widget** with the current script and settings, scaled to fit, inside the frame of the chosen position (notch shape, corner card, or floating window). Moving the Size or Spacing slider changes the preview *while you drag*. The preview also follows the editor caret, so it shows the part of the script you're editing. It does not auto-scroll on its own.
- **Inspector under the preview** has only what matters before starting:
  - **Follow:** Normal / Voice / Audio. Each shows one line of explanation underneath. Audio shows "Choose recording…" inline (POC behaviour).
  - **Position:** three tiles with pictures, not a dropdown. Corner shows a 2×2 mini-screen picker (POC `CornerPicker`). On Macs without a notch and on Windows, the first tile is called **"Top center"** with a webcam icon.
  - **Text:** Size, Spacing, Theme (swatches), Background opacity. Speed is a Normal-mode setting, so it appears under **Follow** only when Normal is selected.
- **One primary action:** `▶ Start` (⌘↩ / Ctrl+Enter). Starting saves the script (existing invariant).
- **Script list:** human dates ("Today 14:03"), `＋ New script`, delete on hover and right-click (Rename / Duplicate / Show in Finder / Delete). It collapses on narrow windows.
- **Word count + reading time** above the editor (Normal: at the current speed; Voice/Audio: about 150 wpm).
- **Empty state** on first launch: a short sample script plus a "Paste your script or press ⌘O to import" hint.

### 3.2 Preferences window (⌘, / Ctrl+,): everything that isn't per-session

A single small window/sheet with sections:

| Section | Contents |
|---|---|
| General | App appearance (System / Light / Dark; default System), Launch at login (later) |
| Privacy | **Show prompter in screen sharing & recordings**: **off by default**, so the prompter is hidden from capture. Turn it on only if you deliberately want the prompter in your video (e.g. recording a tutorial). The note under it says "Do a 10-second test recording before going live". Send crash reports (opt-in) |
| Teleprompter rig | **Mirror text** (for beam-splitter glass), with an explanation. Rotate is **not shown on desktop**. |
| Shortcuts | View and change the global shortcuts (§3.6) |
| Display | Which display the prompter opens on (POC "Same as Script Studio" picker), shown only with more than one display |

Removed from the main screen: Studio appearance, Crash reports, Rotate 180°, Click-through, Hide from screen capture, Mirror.

### 3.3 The prompter overlay: one control set, three densities

Same controls in the same order everywhere. Text labels in the full layout, icons with tooltips in compact and notch.

```text
FULL (floating, large)
┌──────────────────────────────────────────────────────────────────┐
│ ✕ Close    ✎ Edit script     VOICE · LISTENING         Position ▾│  ← drag bar
│                                                                  │
│            …the active word is highlighted here…                 │
│                                                                  │
│   ⟲ Restart   ◀◀ Slower   [ ▶ Play / ● Listening ]   Faster ▶▶   Aa │
│   Space play/pause · ↑↓ speed · Esc back to script · ⌘Q quit      │
└──────────────────────────────────────────────────────────────────┘

COMPACT / NOTCH (controls appear on hover)
   [▶] [◀◀] [▶▶] [⟲] [Aa] [⌖ Position] │ [✎] [✕]
```

- **Close (✕)** always ends the session and returns to Studio. **Edit script (✎)** does the same but focuses the editor at the word you were reading. Both are at the far end, separated from playback controls.
- **Position ▾** is a labelled menu: *Top center (under camera)* / *Corner ▸* / *Floating*, plus *Width* for top center. Not a mystery icon.
- **The eye toggle is removed.** Instead, a small **shield badge** ("Hidden from screen sharing") shows for 3 s when the prompter opens, and again whenever the setting is off (as an orange "Visible to viewers" badge that stays). You can't turn it off from the overlay. That lives in Preferences.
- **Aa popover:** Size, Spacing, Opacity. These are the same sliders with the same ranges as Studio, from one shared widget. Mirror moves to Preferences.
- **Restart** moves into the playback group, where it belongs.
- **Settings stay in sync:** any change on the overlay is the same `settingsProvider` value, so returning to Studio shows it in the preview. This already works; keep it.

### 3.4 Leaving: always one step away

| Where you are | Close prompter → Studio | Quit app |
|---|---|---|
| Overlay | ✕ button, **Esc**, ⌘W / Ctrl+W | ⌘Q / Alt+F4 when the overlay has focus |
| Any app (overlay unfocused) | Global shortcut (§3.6) | Menu bar / tray → Quit |
| **macOS menu bar icon** (new) | "Back to Script Studio" | "Quit EchoPrompt ⌘Q" |
| **Windows tray icon** (new) | "Back to Script Studio" | "Exit" |
| Studio window | — | Standard close/quit (closing the Studio window on macOS keeps the app in the Dock, as now) |

- The **menu bar / tray icon** only appears while the prompter is open. Its menu: Play/Pause · Slower/Faster · Restart · Position ▸ · Back to Script Studio · Quit. It's the safety net when the overlay is off-screen or hidden.
- **Quitting during a session** asks nothing. The script is already saved at Start.
- Escape on Studio does nothing (no surprise quits).

### 3.5 Click-through and Lock: removed

Click-through (and the Lock button that replaced it) is gone. It only helped when the prompter covered something you had to click, and moving or resizing the prompter does that. A locked prompter ignored every click, so it was easy to get stuck. The prompter simply behaves like a normal window: clicks outside it go to the app under them, and hovering it shows its controls. *(Decided after trying it, 2026-10-18.)*

### 3.6 Global shortcuts (work while Zoom/Keynote/OBS has focus)

| Action | macOS default | Windows default |
|---|---|---|
| Play / pause / toggle listening | ⌃⌥Space | Ctrl+Alt+Space |
| Slower / faster | ⌃⌥↓ / ⌃⌥↑ | Ctrl+Alt+↓ / ↑ |
| Restart | ⌃⌥R | Ctrl+Alt+R |
| Show/hide prompter | ⌃⌥P | Ctrl+Alt+P |
| Back to Script Studio | ⇧⌘E (existing) | Ctrl+Shift+E |

Implementation: `RegisterHotKey` on Windows; Carbon `RegisterEventHotKey` on macOS (needs no Accessibility permission). Both go in `echoprompt_window`. All are configurable in Preferences → Shortcuts. Local shortcuts while the overlay has focus stay as now: Space, Esc, plus ↑/↓ for speed and ⌘+/⌘− for text size.

### 3.7 First run (≤ 3 screens' worth of attention)

1. Studio opens with a sample script, and the preview already shows the notch/top-center shape.
2. A one-line tip under Position: "Top center puts your words right under the camera, so you keep eye contact."
3. On first Start: a 3-second toast on the overlay — "Hidden from screen sharing · Esc to go back · ⌃⌥Space to play from any app".
4. Voice/Audio: permission priming happens when you **select** the mode in Studio (as the POC does), never mid-presentation.

---

## 4. Platform differences (macOS vs Windows)

| Topic | macOS | Windows |
|---|---|---|
| Top position name | "Notch" on notched Macs, "Top center" otherwise | "Top center (under webcam)" |
| Overlay above menu bar | Yes (notch placement) | Docks below the screen top. Respect the taskbar if it's on top. |
| Safety net | Menu bar status item (`NSStatusItem`) | Notification-area tray icon |
| Quit | ⌘Q, app menu | Alt+F4, tray → Exit |
| Preferences | ⌘, opens a Settings window | Ctrl+, opens Settings; also a ⚙ button in the Studio toolbar (both OSes) |
| Shortcut glyphs | ⌘ ⌥ ⌃ ⇧ | Ctrl, Alt, Shift spelled out |
| Studio chrome | Native title bar, unified toolbar look | Standard title bar; Mica background on Windows 11 if cheap via `window_manager`, otherwise solid |
| Capture-hiding fallback | — | Windows < 10 2004: Preferences shows "Not supported on this Windows version"; the overlay shows the orange "Visible to viewers" badge |
| Rotate 180° | Hidden | Hidden |
| Mirror | Preferences → Teleprompter rig | Same |

---

## 5. Implementation plan

Ordered so each step ships something visible.

### Step 0: bug fixes (half a day, do first)
- `studio_screen.dart`: Spacing slider `0…40` → `0.9…2.0`; Speed `5…300` → `5…100` (match POC and the overlay).
- Clamp `lineSpacing`/`speed` on load in `PromptSettings.fromJson`, so values already saved by the broken slider get fixed.
- Human-readable labels for every enum (`PromptTheme`, `PromptPlacement`, `PromptCorner`, `StudioAppearance`, mode).

### Step 1: shared controls
- Extract a `PromptTextControls` widget (size, spacing, opacity, theme) used by **both** the Studio inspector and the overlay's Aa popover. One range, one label format.
- Extract `PositionPicker` (tiles + corner mini-screen), used in Studio and as the overlay menu's data source.

### Step 2: live preview in Studio
- New `features/studio/prompt_preview.dart`: wraps `PromptSurface` (static, no ticker) in the chosen position's frame (`_NotchClipper`, corner card, floating card), scaled with `FittedBox` from the real overlay size.
- `PromptSurface` needs a "preview" input: a fixed scroll offset taken from the editor caret's word index, with no playback controller.
- Three-column layout from §3.1; below ~1000 px wide, the preview stacks under the editor; below ~700 px, the script list becomes a drawer.

### Step 3: Preferences window + declutter
- New `features/settings/preferences_screen.dart` (opened as a dialog/route; ⌘, / Ctrl+,).
- Move: app appearance (add *System*), crash reports, hide-from-capture, mirror, display picker, shortcuts.
- Hide-from-capture shows as the inverted switch **"Show prompter in screen sharing & recordings"** (off = hidden). The stored setting stays `hideFromCapture` (default `true`), so existing settings and the POC migration don't change.
- Remove from desktop UI: Rotate 180° (keep the setting for mobile), the click-through switch, the overlay eye toggle.

### Step 4: overlay controls + exits
- Reorder controls per §3.3; add ✕ Close and ✎ Edit as separate actions; Restart moves into the playback group; Position becomes a labelled menu.
- Shield badge (timed) / orange "Visible to viewers" badge (persistent).
- Shortcuts: Esc, ⌘W/Ctrl+W, ⌘Q, ↑/↓ speed, ⌘+/⌘− size.
- *Edit script* returns with the editor caret at the last reading position.

### Step 5: menu bar / tray + global shortcuts
- `echoprompt_window`: `NSStatusItem` (macOS) and `Shell_NotifyIcon` (Windows) with a menu driven from Dart; `RegisterEventHotKey` / `RegisterHotKey`.

### Step 6: first-run polish
- Sample script, Position tip, first-Start toast, Studio empty state.

### Acceptance checks (manual, per OS)
- [ ] Dragging Size/Spacing/Opacity/Theme in Studio changes the preview while dragging, and the overlay matches the preview on Start.
- [ ] From the overlay, you can reach Studio in one action and quit in one action, with no Studio detour.
- [ ] With the overlay unfocused (Zoom in front), play/pause, speed and back-to-Studio work through global shortcuts and the menu bar/tray.
- [ ] There's no control on the overlay that turns capture hiding off; a fresh install is hidden from capture, and only the Preferences switch makes it visible.
- [ ] No raw enum names anywhere; no Rotate on desktop; "Notch" only on notched Macs.
- [ ] Old saved settings with an out-of-range `lineSpacing` load as a sane value.

---

## 6. Decisions (2026-10-18)

1. **Controlling a locked overlay:** superseded. Lock was removed (§3.5).
2. **Screen-capture hiding:** **always hidden by default.** The only way to make the prompter visible is the Preferences → Privacy switch **"Show prompter in screen sharing & recordings"** (off by default), for users who deliberately want it in their video. There is no control for it on the overlay. When the switch is on, the overlay shows the persistent orange "Visible to viewers" badge (§3.3).
3. **Edit while presenting:** **not in this plan.** Editing still means *Edit script* → Studio, which returns at the last reading position.

## 7. Future (only if users ask)

| Idea | Why it's deferred |
|---|---|
| Edit the script while the overlay keeps running (Studio window next to the live prompter) | Needs Flutter multi-window, which `cross-platform-plan.md` §3.3 avoids for now |

---

## 8. Implementation status (2026-10-18)

Steps 0–6 of §5 are implemented in `app/` and `packages/echoprompt_window/`.

**Where things live**

| Plan item | Code |
|---|---|
| Step 0: ranges, enum labels | `core/settings/prompt_settings.dart` (`PromptLimits`), `core/settings/labels.dart` |
| Step 1: shared controls | `ui/prompt_text_controls.dart`, `ui/position_picker.dart` |
| Step 2: Studio + live preview | `features/studio/desktop_studio_screen.dart`, `features/studio/prompt_preview.dart` (`PromptSurface.previewWordIndex`) |
| Step 3: Preferences | `features/settings/preferences_screen.dart` |
| Step 4: overlay controls + exits | `features/prompter/desktop_prompter_screen.dart` |
| Step 5: tray, global shortcuts | Dart: `echoprompt_window.dart`, `core/shortcuts/shortcut_binding.dart`. Native: `EchopromptWindowPlugin.swift` (`NSStatusItem`, Carbon `RegisterEventHotKey`), `echoprompt_window_plugin.cpp` (`Shell_NotifyIconW`, `RegisterHotKey`) |
| Step 6: first run | sample script (`StudioNotifier.welcome`), position tip, first-start banner |

**Also fixed along the way**
- `PrompterWindow.options()` never sent `notchSize` / `cornerSize`, so the *Notch width* menu did nothing and any window update reset the notch height. Both are now sent.
- Saved `lineSpacing` / `speed` values outside the valid range (from the old 0–40 / 5–300 sliders) fall back to the defaults when loaded.
- The persisted `clickThrough` setting is gone, and so is Lock (§3.5). A persisted `rotated` is ignored on desktop, so an old value can't leave the text upside-down with no way to undo it.
- The mobile Studio screen keeps its layout (mobile gets its own plan) but gets the corrected slider ranges and readable labels.

**Deviations from the plan**
- **Lock / click-through was removed** after trying it (§3.5).
- **Quit** is in the prompter's ⋯ menu, the tray menu, and Ctrl+Q on Windows. On macOS ⌘Q is the system's.
- **Display picker** (Preferences → Display) is not built. It needs native display listing on both OSes. Deferred.
- **Reading time** assumes about 150 words per minute for every mode. It does not yet use the Normal-mode scroll speed.
- **Script list** actions are Duplicate, Show in Finder / Explorer and Delete. *Rename* is left out, because a script's name comes from its first line.
- **Global shortcuts** are registered only while the prompter is open, so they never steal keys while you're editing.
- The Studio's *Hidden from screen sharing* line and the Preferences switch are the only places that mention capture state, as planned. The prompter shows only the opening banner and, if capture hiding is off or unsupported, the orange *Visible to viewers* badge.

**Changes after first review (2026-10-18)**
- Defaults are now 25 pt text and 1.0× line spacing.
- The Midnight / Paper / Ember theme is removed everywhere. The prompter is always white text on black (it never matched the app's light/dark mode), so the swatches in §3.1 and §3.3 no longer exist.
- Background opacity now applies in every position. Previously the Notch layout was always solid black, so the slider did nothing there. Beside a hardware notch, the strip stays solid black and the panel below follows the setting.
- Script Studio shows the capture-visibility line only when the prompter is visible in recordings; the hidden default shows nothing.
- On macOS the control bar now appears on hover even when another app is in front. Before, the window only tracked the mouse while it was the key window, so it took a click first.

**Verification**
- `flutter analyze`: no issues. The macOS debug build compiles with the new Swift plugin code.
- **The Windows C++ has not been compiled or run** (it was written on a Mac). It needs a build and the manual checks below on a Windows machine before release.
- No automated tests were added, per the repository's rule against unrequested tests.

**Manual checks still needed (per OS)**
- [ ] Menu-bar / tray icon appears while the prompter is open, disappears on exit, and its items work.
- [ ] Each global shortcut works with another app in front, and a shortcut already taken by another app fails quietly.
- [ ] Hide / show prompter from the tray and by shortcut.
- [ ] Capture hiding verified with the recording tools in `.claude/specs/prompter-invisibility-and-placement.md` (and Windows 10 < 2004 shows the orange badge).
