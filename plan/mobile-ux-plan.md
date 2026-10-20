# Mobile (iPhone / iPad / Android) UX plan

Status: reading screen + navigation to it implemented (not yet run on a simulator; `flutter analyze lib` clean). Desktop UI untouched.

## Design decisions

- **Reading screen** (`app/lib/features/read/read_screen.dart`): full-bleed white-on-black text. Controls fade a few seconds after playback starts (only while playing); tapping the text brings them back, and that first tap does not seek to a word.
- **Tracking status pill** stays visible at the top even when chrome is hidden. States: Scrolling, Listening (green, pulsing dot), Following audio, Syncing audio…, Paused, End of script, Lost your place, Unavailable (+ reason). Derived from `PrompterState` (see "Shared-code changes" for the one controller addition).
- **Dock**: Restart, large amber Play/Pause, stepper (speed in Normal mode, text size in Voice/Audio). Thin progress line along the bottom edge.
- **Reading settings** (`read/reading_settings.dart`), progressive disclosure: mode, audio file, text size, spacing, speed, mirror, rotate (+ overlay opacity, appearance, crash reports when opened from Studio). Bottom sheet on narrow windows, side panel on wide.
- **Navigation** (`studio/studio_screen.dart`): narrow = Scripts list -> editor -> Read; each row has a play button to read immediately. Wide (>= 720pt) = list and editor side by side. Layout follows window width, never device type.
- **Wide Studio**: the right pane shows a "Choose a script" empty state (New script / Import) until a script is opened or created, so a blank text box never sits next to the "New script" button. Deleting the open script returns to that state.
- **Editor action bar**: Preview and Record share the row equally and keep their labels on one line. In short, wide windows (phone landscape) the bar collapses to a single row (mode picker + stats on the left, buttons on the right) so the script keeps the height.
- **Wide reader**: text column capped at ~980pt, larger dock, side settings panel.
- **Theme** (`ui/mobile_theme.dart`): warm off-white / charcoal surfaces, amber accent; used on mobile only (`main.dart` keeps the desktop theme on desktop).
- **iPad keyboard**: Space toggles play, Esc closes the reader.

## Mode model (confirmed with product owner)

Three modes, each with a distinct purpose. The mode decides what the primary action does; modes are not merged or decoupled.

| Mode | Purpose | Camera / mic |
|---|---|---|
| **Normal** | Plain teleprompter at a set speed. The user records with a different device or app (another phone, a computer mic, a news-style studio setup). | None. Never touches the camera or microphone. Primary action: **Read**. |
| **Voice** | The common creator case: speak from a voice-following prompter while the app records video and audio (front or back camera). | Camera + mic. Primary action: **Record**. Noise cleanup is out of scope. |
| **Audio** | For people who prefer not to record their own voice: a pre-recorded or TTS audio file. On Record the camera starts, the file plays and the prompter follows it. | Camera. **The recorded video must contain the audio file's sound.** Primary action: **Record**. |

Audio mode's reason to exist is look-ahead: the text shows the line being spoken plus the next 1-2 lines, so the person can act early (e.g. turn the camera to the river before the narration reaches it). Keep upcoming lines readable on the overlay.

Voice and Audio also offer **Preview** (the Read screen, no camera) for rehearsal.

### Voice recovery
- The matcher always continues from the last recognised word; repeating the last phrase recovers, as on desktop. This is unchanged.
- New: when speech is heard but does not match for ~4 s, the status pill shows **Lost your place** with a hint. Silence never triggers it. It clears when the highlight moves, on tap, pause or restart.
- Tap any word to move the highlight there (existing `seekTo`); optional shortcut, not a replacement.
- Desktop prompter ignores the new `lost` flag and has no word-tap (its text area drags the window), so desktop is unchanged.

### Audio mode sound
- Today the camera plugin records the built-in mic only. To get the file's sound into the video, Audio mode defaults to the **Speaker** route (the mic picks up the playback). Headphones / Silent remain available in the Record menu, labelled "not in the video".
- Known limit: this depends on speaker volume and room acoustics. The clean fix is already planned as Phase 3 in `cross-platform-plan.md`: write the file as the video's audio track in the native encoder. Needs native work in `echoprompt_camera` (iOS and Android); not started.

## Shared-code changes

- `prompt_surface.dart`: optional `onTapIntercept` (null on desktop).
- `main.dart`: mobile vs desktop theme.
- `prompter_controller.dart`: `PrompterState.lost` + 4 s stall timer in Voice mode (desktop ignores it).
- `prompter/tracking_status.dart`: shared status derivation and pill, used by the Read screen and the Record overlay (`PromptView`).
- `record_screen.dart`: Audio mode defaults to the Speaker route; menu labels say whether audio is in the video.
- `studio_screen.dart`: editor bar has a mode selector, a one-line plan of what the button does, an audio-file chip in Audio mode, and Read / Preview + Record buttons.

## Behaviour changes to be aware of

- Mirror / Rotate moved from reader buttons into the settings sheet.
- Old inline studio settings panel replaced by the settings sheet.
- Script delete moved from inline trash icon to a "⋯" menu with confirmation.

## Next steps

- Verify on iPhone and iPad simulators (portrait/landscape, resize, large text, light/dark, keyboard).
- Restyle the Record screen to match the Read screen (overlay still uses `PromptView`, now with the shared status pill).
- Decide whether Audio-mode overlay should show more look-ahead lines than the shared compact layout does (changing the shared surface would affect desktop).
- Native: mux the audio file into the video soundtrack (Phase 3).
- Polish Settings / preferences.
