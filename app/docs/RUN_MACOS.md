# Running EchoPrompt on macOS

This guide covers the Flutter desktop app in `app/`. It explains how to run it,
how to build a copy you can open like any other app, and what to check by hand.

## Requirements

- macOS 13 or later (the desktop overlay uses modern window APIs).
- Flutter (stable channel) and Xcode with its command-line tools.
  Check with `flutter doctor`; the macOS row must have no errors.
- For Voice and Audio modes only: the English speech models (see below).
  Normal mode works without them.

## Run it (developer)

From the repository root:

```sh
cd app
flutter pub get
flutter run -d macos
```

This builds a debug version and opens it. Press `r` in the terminal to hot reload
after a Dart change, or `R` to restart. Native Swift changes need a full restart.

## Build it as an app (no terminal needed afterwards)

```sh
cd app
flutter build macos --debug      # or: flutter build macos --release
open build/macos/Build/Products/Debug/EchoPrompt.app
```

Drag `EchoPrompt.app` to `/Applications` if you want to keep it. The release
build (`--release`) is the one to use for real presentations; it is faster.

## Speech models (only for Voice and Audio modes)

The models are not stored in git. Download them once:

```sh
cd app
./tools/fetch_models.sh
```

This fills `app/assets/models/en/online` and `app/assets/models/en/offline`.
Rebuild the app afterwards, because the models are bundled at build time.

## Permissions

macOS asks the first time a mode needs them:

| Mode | Asks for |
|---|---|
| Normal | Nothing. It never opens the microphone. |
| Voice | Microphone and speech recognition, when you pick Voice in Script Studio. |
| Audio | Nothing extra, but you must choose a recording file. |

If you denied a permission and want it back, open **System Settings → Privacy &
Security**, choose **Microphone** (or **Speech Recognition**), and turn on
EchoPrompt. Restart the app afterwards.

Running `flutter run` uses a development signature, so macOS may ask again after
each rebuild. That is expected.

## Resetting saved settings

Your settings are remembered between runs, so new defaults only apply to a fresh install.
To go back to the defaults, quit the app and run:

```sh
defaults delete com.echoprompt.app flutter.EchoPrompt.settings.v2
```

## Using the app

1. **Script Studio** opens first. Paste or type your script, or use the
   import button.
2. Choose how it follows you (**Normal**, **Voice** or **Audio**) and where it
   sits (**Top center** or **Notch**, **Corner**, **Floating**). The live preview
   on the right shows exactly what you will see.
3. Press **Start** (⌘↩).
4. The prompter opens above your other windows. To leave it, use any of:
   - **✕ Close** or **Esc**: back to Script Studio.
   - **Edit script**: back to Script Studio, with the cursor on the word you were reading.
   - **⋯ → Quit EchoPrompt** or **⌘Q**: quit the app.
   - The **menu-bar icon** (top right of the screen, while the prompter is open).
   - Global shortcuts, which also work while another app is in front (see below).
5. **Preferences** (⌘,) holds the privacy switch, mirror, appearance, crash
   reports and shortcuts.

### Global shortcuts (default)

These work while the prompter is open, even when another app is in front.

| Action | Shortcut |
|---|---|
| Play / pause | ⌃⌥Space |
| Slower / faster | ⌃⌥↓ / ⌃⌥↑ |
| Restart | ⌃⌥R |
| Show / hide prompter | ⌃⌥P |
| Back to Script Studio | ⇧⌘E |

Change them in **Preferences → Shortcuts**. If a shortcut is already used by
another app, it simply does nothing, so pick another combination.

### Privacy

The prompter is **hidden from screen sharing and recordings by default**. The
**Preferences → Privacy** switch "Show prompter in screen sharing & recordings"
is off by default. Turn it on only when you want the prompter in your video. When
it is on, the prompter shows an orange **Visible to viewers** badge, and Script Studio shows
"Visible in screen sharing and recordings" above Start. When hiding is on (the default),
Studio shows no message.

Hiding is best-effort: it works with the common tools (QuickTime, ⇧⌘5, Zoom,
Teams, Meet, OBS window capture). Do a short test recording before going live.

## Manual test checklist

Run through these by hand after each build.

**Studio**
- [ ] Dragging **Text size**, **Line spacing** and **Background opacity** changes the preview immediately.
- [ ] A fresh install starts at 25 pt text size and 1.0× line spacing.
- [ ] **Spacing** and **Speed** stay within their ranges (0.9–2.0× and 5–100).
- [ ] Choosing **Corner** shows the corner picker; clicking a corner moves the preview.
- [ ] Narrowing the window stacks the editor above the controls with no clipped text.
- [ ] Start is disabled when the script is empty.
- [ ] A script you start appears in the list with a time such as "Today 14:03".

**Prompter**
- [ ] Opens above other apps, and Esc returns to Script Studio.
- [ ] **Edit script** returns with the cursor on the word you were reading.
- [ ] ⋯ → Quit EchoPrompt quits the app.
- [ ] A menu-bar icon appears while the prompter is open and disappears after you leave it.
- [ ] Hide / show works from the menu bar and by ⌃⌥P.
- [ ] While another app is in front, ⌃⌥Space plays and pauses.
- [ ] "Visible to viewers" shows only when the Preferences switch is on.
- [ ] With the Compact, Corner or Notch layout, the control bar appears when you hover the prompter, without clicking it first, even while another app is in front.
- [ ] Background opacity changes the prompter in every position. Under a camera notch, the strip beside the notch stays solid black and the panel below it follows the setting.

**Recording check (do before a real presentation)**
- [ ] With the switch off, a QuickTime screen recording of the desktop does not show the prompter.

## Troubleshooting

- **Voice or Audio mode shows no words**: check the permissions above, and that the
  speech models are downloaded and the app was rebuilt afterwards.
- **No menu-bar icon**: the icon appears only while the prompter is open. The keyboard
  shortcuts and Esc still work without it.
- **A shortcut does nothing**: another app already uses those keys. Pick another in
  Preferences → Shortcuts.
- **Build fails after pulling changes**: run `flutter clean && flutter pub get`, then build again.

## Notes

- Windows uses the same steps with `flutter run -d windows`. Its native code has not
  yet been built on Windows; see `plan/desktop-ux-plan.md` §8.
