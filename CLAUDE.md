# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Task scope and execution rules

- Implement only the requested change and the directly necessary supporting
  changes. Do not add extra features, speculative improvements, unrelated
  refactors, formatting changes, or dependency upgrades.

- Do not create, modify, repair, or run tests unless the user explicitly
  requests testing. Do not introduce test frameworks, linters, or other
  development tooling as part of an implementation task.

- If you discover an unrelated bug or a pre-existing build failure, leave it
  unchanged and briefly mention it in the final response. Fix errors caused
  by your own changes.

- For explanation, review, or planning requests, do not modify files or run
  implementation commands unless requested.

- Follow existing architecture and coding conventions. Do not split files,
  introduce abstractions, or restructure the project unless necessary for
  the requested outcome.

- When creating or modifying any UI component or layout, ensure equal spatial
  distribution and uniform spacing (consistent padding, margins, gaps, and
  alignment between sibling elements) so the UI looks polished and balanced.
  Reuse existing spacing values and conventions rather than introducing
  one-off numbers.

## Efficient investigation and validation

- Start with targeted searches and read only the relevant code sections.
  Expand investigation when needed to understand dependencies or behavior;
  avoid repeatedly reading entire files or scanning unrelated directories.

- Use the smallest relevant validation for the change. For Swift changes,
  prefer `swift build`; for web code changes, use `npm run build` from `web/`
  when appropriate. Skip builds for documentation-only changes.

- Do not repeatedly rebuild after a successful check unless further changes
  or new evidence require it. Do not run both projects' builds when only one
  project is affected.

- Do not install dependencies unless required to complete the requested task
  or its relevant validation. Preserve existing dependency versions and
  avoid incidental lockfile changes.

- Do not launch apps, start development servers, or request microphone/speech
  permissions unless needed for the requested task. When a bundled macOS
  build is needed without launching, use:
  `ECHO_PROMPT_OPEN_AFTER_BUILD=0 ./build-app.sh`

## Completion and communication

- Make routine implementation decisions independently. Ask for clarification
  only when ambiguity materially affects the requested behavior.

- Keep progress updates and the final response concise. Report what changed,
  relevant validation results, and any remaining blocker. Do not reproduce
  large code sections or command logs unless requested.

- Stop when the requested behavior is implemented and relevant validation
  is complete. Do not start optional cleanup or additional improvement work.
  
## Repository layout

Two independent projects share this repo:

- **Root** — EchoPrompt, a native macOS 13+ teleprompter (SwiftUI + AppKit, Swift Package, no third-party dependencies). The package is named `EchoPrompt`; the target/source folder is still `TelePrompterApp`.
- **`web/`** — the Next.js (App Router, TypeScript) marketing site, deployed separately via Netlify (`netlify.toml` sets `base = "web"`).
- **`Sources/`**  - it is old poc and sometimes considered as a reference when explcily specified. Currently our implementation is happening with flutter framework.

There are no tests or linters configured in either project.

## Commands

macOS app (run from repo root):

```sh
swift build                          # debug build
swift run                            # run bare executable (Normal mode only — see below)
./build-app.sh                       # release build → .build/EchoPrompt.app, ad-hoc signed, then opens it
ECHO_PROMPT_OPEN_AFTER_BUILD=0 ./build-app.sh   # build bundle without launching
```

Web site (run from `web/`):

```sh
npm install
npm run dev      # http://localhost:3000
npm run build    # also the Netlify build command
```

`NEXT_PUBLIC_SITE_URL` (canonical HTTPS URL, no trailing slash) drives canonical metadata, `robots.ts`, and `sitemap.ts`; the site intentionally doesn't guess a production domain.

## macOS app architecture

All app code lives in one file: `Sources/TelePrompterApp/TelePrompterApp.swift`.

- **`PrompterModel`** (single `ObservableObject`, created in `EchoPromptApp`) owns all settings, the script, the saved-script history, and the floating prompt window. It owns one `VoiceScrollController` and one `RecordedAudioController`.
- **Two windows**: Script Studio (`EditorView` in the SwiftUI `WindowGroup`) and the prompt, a borderless non-activating `PromptPanel` (`NSPanel` subclass, all Spaces) hosting `PromptView` via `NSHostingView`. `applyPlacement(animated:)` reconfigures its level/frame for the Notch, Corner, or Floating placement (`PromptPlacement`), and `PromptView` switches between `.full`, `.compact`, and `.notch` layouts. `hideFromScreenCapture` sets `sharingType = .none` on the panel (best-effort); popovers need `CaptureVisibilityProbe` because they are separate windows. Spec: `.claude/specs/prompter-invisibility-and-placement.md`. `openPrompter()` hides the studio window and shows the panel; `closePrompter()`/`restoreWorkspace()` reverse it. Click-through is implemented with `panel.ignoresMouseEvents`.
- **The panel is created once and reused.** `presentationSessionID` is regenerated on every `openPrompter()` and is the signal `PromptView` must use to reset scroll position, highlighting, and playback state — preserve this when changing prompt state.
- `AppDelegate` and the `.restoreEchoPromptWorkspace` notification handle Dock-reopen / `⇧⌘E` behavior (don't restore the studio while a prompt panel is visible).
- **Three modes** (`PromptControlMode`): Normal (timer-based scrolling at `speed`), Voice (`VoiceScrollController`: `AVAudioEngine` tap + `SFSpeechAudioBufferRecognitionRequest`, publishes `newWords`), Recorded audio (`RecordedAudioController`: `AVAudioPlayer` + `SFSpeechURLRecognitionRequest`, maps timestamped transcript tokens to script word indices). Word highlighting state is expressed via `PromptReadingProgress`.
- **Matching is deliberately conservative**: short/common words only advance when they are the next expected word, and jumps require nearby phrase confirmation. Favor falling behind over skipping ahead when modifying this logic. Note that `normalized(_:)` is duplicated in `RecordedAudioController` and `PromptView`.
- Normal mode must never touch `AVAudioEngine.inputNode` (it can trigger a microphone prompt) — see `hasActiveAudioTap`.
- **Persistence**: script history metadata is JSON in `UserDefaults` (`EchoPrompt.scriptHistory.v1`, max 20 entries); script bodies are written as `.txt` files to `~/Documents/EchoPrompt Scripts`, with filenames derived from the script's first lines. Starting the prompter saves the script.

### Permissions gotcha

Voice and Recorded Audio modes need `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`, which only exist in the bundled `Info.plist`. Under `swift run` the code detects their absence and shows a status message instead of requesting access (macOS would otherwise kill the process). Test those modes with `./build-app.sh`.

## Shared assets

`Assets/EchoPromptAppIcon.png` is the single source icon: `build-app.sh` converts it to `.icns`, and `web/app/icon.png` is an identical copy used as the site favicon. Update both together.

## Web site notes

- `web/app/page.tsx` is a Server Component; primary content and FAQ work without client JS — keep it that way.
- `next.config.mjs` sets `outputFileTracingRoot` to `web/` because the site is nested inside the Swift repo; don't remove it.
- `web/README.md` describes Vercel deployment, but the repo is actually configured for Netlify.
