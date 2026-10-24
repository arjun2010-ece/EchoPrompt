# EchoPrompter

**EchoPrompter** is a native macOS teleprompter for presenters, educators, creators, and developers who want a focused script-reading experience without leaving their workflow. Write or paste a script in Script Studio, choose how it should advance, and present it in a floating, always-on-top prompt near the camera.

The app is built with SwiftUI and AppKit for macOS. It supports normal automatic scrolling, hands-free voice following, and recorded-audio playback synchronized to a matching script.

## Highlights

- **Three ways to follow a script**
  - **Normal** — smooth automatic scrolling with adjustable pace.
  - **Voice** — follows a live speaker using macOS Speech Recognition and pauses naturally when speech stops.
  - **Recorded audio** — plays a local audio file and advances the script in sync with its recognised words.
- **A purpose-built presentation window** — an always-on-top, resizable floating prompt positioned near the top of the display, where it is convenient to read near a camera.
- **Word-level reading feedback** — in Voice and Recorded Audio modes, completed words soften, the active word is orange and underlined, and upcoming words remain prominent.
- **Reading controls that adapt to the mode** — normal scrolling offers playback-rate controls; Voice and Recorded Audio modes are paced by their source instead.
- **Prompt customization** — tune text size (16–110 pt), line spacing, prompt theme, studio appearance, prompt opacity, and mirrored text.
- **Click-through presentation** — optionally let mouse clicks pass through the floating prompt to VS Code, a browser, or another app behind it.
- **Local script library** — scripts are automatically stored as readable `.txt` files in `~/Documents/EchoPrompter Scripts`, with a recent-scripts picker for loading or deleting them.
- **Recording-friendly workflow** — capture only the app or display you intend to show in OBS, ScreenFlow, QuickTime, or another recorder while reading EchoPrompter above it. EchoPrompter does not attempt to hide itself from screen-recording software.

## Modes

| Mode | Best for | How it advances |
| --- | --- | --- |
| Normal | Practised scripts and consistent pacing | Continuous automatic scrolling at the selected reading pace |
| Voice | Live delivery, rehearsals, and flexible pauses | Speech recognition follows the script as the presenter speaks |
| Recorded audio | Voice-overs, rehearsals, and prerecorded narration | The selected local audio file plays while recognised words advance the matching script |

For the most accurate Voice and Recorded Audio results, use a script that closely matches the spoken wording. Recognition is intentionally conservative: it prefers briefly falling behind rather than incorrectly jumping several sentences ahead.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools
- Microphone access for **Voice** mode
- Speech Recognition access for **Voice** and **Recorded Audio** modes

## Run in development

```sh
swift run
```

This is useful for basic development, especially Normal mode. A Swift Package executable is shown as `exec` in the Dock and is not the recommended way to test macOS privacy permissions.

## Build the macOS app bundle

Use the supplied script for a packaged app with the required privacy declarations and an ad-hoc local signature:

```sh
./build-app.sh
```

The script builds a release executable, creates `.build/EchoPrompter.app`, signs it locally, and opens it.

Use this packaged app to test Voice and Recorded Audio modes:

```sh
open .build/EchoPrompter.app
```

> For public distribution, replace the ad-hoc signature with a proper Developer ID signing and notarization workflow.

## Using EchoPrompter

1. Open **Script Studio** and paste or write a script.
2. Choose a follow mode in **Prompt behaviour**:
   - Select **Normal** for continuous scrolling.
   - Select **Voice** to grant Speech Recognition and Microphone access before presenting.
   - Select **Audio**, then choose a local recording that matches the script.
3. Adjust reading pace, text size, line spacing, theme, and studio appearance as needed.
4. Press **Start EchoPrompter** or `⌘↩` to open the floating prompt.
5. Use the on-screen controls:
   - **Normal:** slower, play/pause, and faster controls adjust reading pace.
   - **Voice:** start or stop listening; the prompt follows spoken words.
   - **Audio:** play/pause the selected recording; the prompt follows its playback.
   - **Text:** opens live text-size and line-spacing controls.
   - **Mirror text:** flips the prompt horizontally for compatible teleprompter glass setups.
6. Use the top-right restart button to return to the beginning. Press `Esc` to close the prompt and return to Script Studio.

### Working over another app

Enable **Presentation → Click through prompt** when you need to operate the app beneath EchoPrompter. The prompter stays visible, but clicks pass through it to the underlying window. Return to editing with **Edit script** or `⇧⌘E`.

## Scripts and local storage

Starting EchoPrompter saves the current script locally. Saved scripts:

- appear in **Saved scripts**;
- can be loaded back into Script Studio;
- update their existing entry when an opened script is edited and started again;
- are kept as `.txt` files in `~/Documents/EchoPrompter Scripts`;
- can be deleted from the saved-scripts picker.

The filename is derived from the first meaningful text in the script, rather than an opaque identifier.

## Privacy and permissions

EchoPrompter asks for only the permissions required by the selected mode:

| Permission | When requested | Why |
| --- | --- | --- |
| Microphone | Voice mode | To receive live speech for script following |
| Speech Recognition | Voice or Recorded Audio mode | To match spoken or recorded words to the script |

Normal mode does not request microphone or speech-recognition access. Scripts and chosen recordings are read from local storage; EchoPrompter does not include an account system or its own cloud upload service. Speech recognition is provided by macOS and is subject to Apple’s system settings and availability.

## Screen recording guidance

EchoPrompter is designed to be a visible reading aid, not a screen-recorder bypass. For a tutorial or demo:

1. Put EchoPrompter near the camera over the app you are demonstrating.
2. Configure the recorder to capture only the demonstrated application/window or the intended display source.
3. Keep EchoPrompter outside that chosen capture source.
4. Use Click through prompt if you need to interact with the application beneath it.

Always verify a short recording before publishing it.

## Project structure

```text
.
├── Sources/TelePrompterApp/TelePrompterApp.swift  # SwiftUI/AppKit application
├── Info.plist                                     # App metadata and permission strings
├── Package.swift                                  # Swift Package definition
├── build-app.sh                                   # Release app-bundle build script
└── App-Description.md                             # Product planning notes
```

## Development notes

- The project targets macOS 13+ and has no third-party package dependencies.
- The prompt is hosted in an `NSPanel` so it can remain floating without replacing the Script Studio window.
- Voice and audio synchronization are designed to favour stable, sequential progress over aggressive fast-forwarding when recognition is uncertain.

## License

EchoPrompter is available under the [EchoPrompter Personal Use License](LICENSE). It may be used and modified for personal, non-commercial purposes only. Commercial use, resale, revenue-generating use, and relicensing are prohibited.
