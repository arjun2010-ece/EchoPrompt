# Plan: EchoPrompt on every platform

Status: Draft v6. The two core product requirements below define what "same functionality everywhere" means. Company and legal formalities are an optional **later** phase (Phase 5), so the first goal is to build, launch, and prove people will pay. This version adopts a fast-track approach: build everything in Phase 1, test manually in Phase 2, add analytics and paywall in Phase 3, release in Phase 4.
Date: 2026-10-18

### Core product requirements (the definition of "done")

| # | Platforms | Requirement |
|---|---|---|
| **R1** | **macOS, Windows** | A **floating prompter overlay on top of any application**, **hidden from screen-recording and screen-sharing software**, with **Normal, Voice-controlled, and Recorded-audio** modes |
| **R2** | **iOS, iPadOS, Android** | The app has its **own camera** (front/back) with a **floating prompter overlay on top of the camera preview**, so the user records video while reading. **Normal, Voice-controlled, and Recorded-audio** modes. Works in **portrait and landscape**. |

These two requirements settle the earlier conflict over "the same functionality everywhere":
- **The modes, script handling, and reading experience are identical everywhere.**
- **What the overlay floats over differs by platform:** other apps on desktop, the app's own camera on mobile.

iOS doesn't allow an app to float over other apps, so R2 is the mobile equivalent of R1.

**Scope:** take the EchoPrompt macOS proof of concept (`Sources/TelePrompterApp/TelePrompterApp.swift`) to these platforms, from one codebase:
- **macOS** (Mac App Store only)
- **Windows** (Microsoft Store)
- **iOS**
- **iPadOS**
- **Android** (phones and tablets)

It must be ready for a paid release, with the paywall built in Stage 2.

**Not in scope:**
- **Linux.** It was dropped because the user base is small and feature parity isn't achievable there:
  - no way to hide from screen capture;
  - Wayland blocks always-on-top windows, positioning, and click-through;
  - no system speech recognition.
  Flutter supports Linux, so it can be added later at low cost if demand appears (§3.4).
- **`web/`** (the marketing site). It stays as it is. The only change is the Google Analytics tracking from Stage 2 (§10.1).

---

## 1. TL;DR

| Decision | Choice |
|---|---|
| Platforms | macOS, Windows, iOS, iPadOS, Android (phone + tablet). **No Linux.** |
| Framework | **Flutter** (Dart, AOT-compiled to native machine code, Impeller rendering) |
| Shared code | About 85–90%: UI, state, script storage, the word-matching engine, playback, paywall logic |
| Native code | Small plugins: `echoprompt_window` (macOS Swift, Windows C++) for the overlay window, notch, click-through, and hide-from-capture; `echoprompt_camera` (iOS Swift, Android Kotlin) for video recording |
| Speech recognition | **sherpa-onnx** streaming ASR. It runs on-device and offline, behaves the same on every platform, and is Apache-2.0. **English only at launch**; more languages ship as downloadable models later. |
| State management | Riverpod |
| Accounts | **Optional EchoPrompt account** (Sign in with Apple / Google / email link). It is needed only to share Pro across devices. |
| Paywall (Stage 2) | 5 free scripts → **Monthly subscription (highlighted default)** or **Lifetime**. One purchase unlocks all of the user's devices. Subscriptions are re-verified at least every 30 days, and **30 days offline at most**, after which the paywall shows (§10.4). |
| Billing | RevenueCat as the single source of truth: App Store (iOS + Mac App Store, shared through Universal Purchase), Google Play, and Paddle (merchant of record) for Windows |
| Backend | Supabase: auth, Postgres, Edge Functions. It signs entitlement tokens, keeps the free-script counter, and proxies analytics. |
| Pricing (Stage 2) | **Monthly €6.99 / $6.99 (highlighted default)** · **Lifetime €59.99 / $59.99**. Prices can be changed later in the store consoles without an app update (§10.4). |
| Business | **Launch as an individual developer** (personal Apple, Google, and Microsoft accounts) to test monetisation first. Forming a Portuguese company and the wider legal set-up is **optional Phase 5**, done once revenue justifies it (§9.2). |
| Analytics (Stage 2) | Google Analytics 4: Firebase on iOS, Android, and macOS; Measurement Protocol on Windows; gtag on the web site. Region-based consent. |
| Desktop overlay (R1) | One floating, always-on-top, click-through-capable prompter window, hidden from capture by default; Normal / Voice / Audio (§7.1) |
| Mobile camera overlay (R2) | In-app front/back camera with the prompter overlay docked at the top; Normal / Voice / **Audio** while recording; portrait + landscape (§10.2) |
| Licensing (Stage 2) | A simple proprietary EULA/Terms that **allows commercial use** (free tier included). The business/OEM licence and lawyer review are Phase 5 (§10.3). |
| App ID | `com.echoprompt.app` on every platform. It is already the POC's bundle ID (§9.2). |
| Swift POC | Stays at the repo root until feature parity, then moves to `legacy/macos-poc/` |

**About "exact same functionality".** The core product is identical everywhere:
- Script Studio and script history;
- **all three follow modes (Normal, Voice, Recorded audio) on every platform**;
- word highlighting, themes, mirror and rotation;
- the paywall.

Only the overlay's *host* differs (R1 vs R2). A few desktop window extras are Mac- or desktop-only: the notch placement, corner snapping, and click-through. §4 lists them.

**One honest limit on R1:** "hidden from recording software" is **best-effort**. It works with the common tools: Zoom, Teams, Meet, QuickTime/⇧⌘5, OBS window capture, and the Windows Snipping Tool/Game Bar. No app can hide from a camera filming the screen, a hardware capture card, or a recorder that ignores the OS flag. The in-app copy says "hidden from most screen-sharing and recording apps" and suggests a quick test recording.

---

## 2. What we are porting (inventory of the POC)

Taken from the current Swift code (about 2,760 lines):

1. **Script Studio:**
   - script editor;
   - saved-script history (max 20, stored as `.txt` files plus JSON metadata);
   - reveal library, choose audio file;
   - settings: font size 16–110, line spacing, speed, opacity, theme, studio appearance, mirror.
2. **Prompter window:** borderless, always on top, non-activating, visible on all Spaces, created once and reused (`presentationSessionID` is the reset signal).
   - Placements: **Notch**, **Corner** (4 corners with snap-to-nearest), **Floating** (frame remembered per display).
   - Layouts: `.full`, `.compact`, `.notch`.
   - **Click-through** (`ignoresMouseEvents`).
   - **Hide from screen capture** (`sharingType = .none`, plus `CaptureVisibilityProbe` for popovers).
   - Handles multiple displays, display hot-plugging, and Space changes.
3. **Follow modes:**
   - **Normal:** timer-driven scrolling at `speed`. Never touches the microphone.
   - **Voice:** live mic → streaming speech recognition → conservative word matching (`follow(spoken:)`, `hasPhraseConfirmation`) → `PromptReadingProgress` (confirmed and predicted index).
   - **Recorded audio:** audio file → offline transcription with word timestamps → `align(...)` to script indices → playback-synced highlighting with `pacingCeiling`.
4. **Word-level UI:** completed words soften, the active word is orange and underlined, and upcoming words stay prominent. Auto-scroll keeps the current word in view.
5. **Persistence:** `UserDefaults` settings (domain `com.echoprompt.app`) and scripts in `~/Documents/EchoPrompt Scripts`.
6. **Permissions:** microphone and speech recognition are requested only for the mode that needs them.

The **matching algorithm** is the main IP and the hardest part to get right. It will be ported to pure Dart **first** and covered by tests (§7.3), and the duplicated `normalized()` will be merged into one function.

---

## 3. Framework decision

### 3.1 Requirements → what they mean technically

| Your requirement | What we need to verify |
|---|---|
| Lightweight / memory-efficient | Native-compiled (no JS bridge, no JVM, no bundled Chromium); low idle RAM |
| Extremely fast | 60/120 fps smooth scrolling of large text, low input latency, fast cold start |
| Does not crash easily | Memory-safe language, mature runtime, good crash reporting, strong typing |
| Huge, mature ecosystem | Plugins for audio, camera, files, storage, IAP, auth, and speech on **all target platforms** |
| Popular | Hiring pool, long-term backing, community answers |
| macOS + Windows + iOS + Android, one codebase | Officially supported, stable targets, not community forks |
| Sellable | License allows closed-source commercial distribution on every app store, including iOS (where static linking is effectively required) |

### 3.2 Candidates compared

| | **Flutter** | Kotlin/Compose Multiplatform | Tauri 2 (Rust + WebView) | Qt 6 (C++/QML) | React Native (+ RN Windows/macOS) | .NET MAUI |
|---|---|---|---|---|---|---|
| macOS / Windows | ✅ stable | ✅ (JVM on desktop) | ✅ | ✅ | ⚠️ Microsoft-maintained forks, which lag behind core RN | ⚠️ macOS only through Mac Catalyst (limited window control: no notch/panel tricks) |
| iOS / Android | ✅ stable, the platform's main use | ✅ (iOS stable since 2025) | ⚠️ newer, thin plugin ecosystem | ✅ | ✅ | ✅ |
| Runtime weight | AOT native + engine (~15–25 MB binary) | **JVM on desktop** (high RAM, slower start) | Very light (system WebView) | Very light | JS engine + bridge | .NET runtime |
| Rendering consistency | Identical pixels everywhere (own renderer) | Identical (Skia) | Differs per OS WebView | Identical | Native widgets differ | Native widgets differ |
| Ecosystem size / popularity | **Largest cross-platform UI ecosystem** (pub.dev), very popular | Growing fast, smaller for desktop | Growing, mobile side young | Mature but niche, costly | Huge for mobile, weak for desktop | Medium |
| Commercial licensing | BSD-3, free | Apache-2, free | MIT/Apache, free | **LGPL, or a paid commercial license** (LGPL is a problem on iOS) | MIT | MIT |
| Native interop for our window tricks | Platform channels / FFI: straightforward | JNI/cinterop: OK | Rust: excellent | C++: excellent | Native modules: OK | P/Invoke: OK |

### 3.3 Recommendation: Flutter

- It ships **all target platforms officially and stably**, has one rendering engine (so the prompter looks and scrolls the same everywhere), **and** has the largest ecosystem.
- Dart compiles AOT to native ARM/x64 code. There is no interpreter or bridge on the hot path. Text scrolling runs on the GPU through Impeller.
- Dart is memory-safe and null-safe, so crash risk sits mostly in our own native plugin code, which we keep small.
- BSD licence, no royalties, and no LGPL problems on iOS.

**Honest trade-offs:**
- **Memory.** A Flutter desktop app uses more memory than the hand-written Swift POC. Expect roughly 80–150 MB idle compared with about 40–60 MB, plus the speech model (§5) while Voice mode is active. That is still far below Electron (300 MB+) and the JVM.
- **Multi-window.** Flutter's desktop multi-window support is still maturing. **We design around it:** the POC already hides Script Studio while presenting, so we use **one native window** that switches between "Studio" configuration and "Prompter" configuration (borderless, top-most, placement frame). Popovers then render inside that same window, which also makes hide-from-capture cover them for free.

**Runner-up:** Tauri 2. It is lighter on desktop, but its mobile ecosystem (camera, IAP, background audio) is young, and that matters more now that Stage 2 adds video recording.

The spike in §8 Phase 0 includes **go/no-go checks** on the riskiest window features before we commit fully.

### 3.4 Does dropping Linux change the decision?
No.
- **React Native and MAUI** become technically possible without Linux. Both are still weaker on the **macOS** side, where our hardest features live (notch panel, window level above the menu bar, capture hiding).
- **Flutter** remains the strongest fit.
- **Bonus:** Flutter keeps a Linux build available later for little extra work. It would need only a small Linux implementation of `echoprompt_window` and a reduced feature set.

---

## 4. Feature parity matrix

✅ same as macOS POC · 🔁 substitute (closest equivalent) · ❌ not possible on that OS · — not applicable

| Feature | macOS | Windows | iOS / iPadOS | Android (phone/tablet) |
|---|---|---|---|---|
| Script Studio, history, themes, fonts, mirror | ✅ | ✅ | ✅ | ✅ |
| Rotation toggle (glass rigs / landscape) | ✅ | ✅ | ✅ | ✅ |
| Normal / Voice / Recorded-audio modes | ✅ | ✅ | ✅ | ✅ |
| Word highlighting | ✅ | ✅ | ✅ | ✅ |
| **R1: floating overlay over any app** (Normal / Voice / Audio) | ✅ | ✅ (`HWND_TOPMOST`) | — (iOS forbids it; R2 instead) | — (R2 instead) |
| **R2: in-app camera + floating overlay** (Normal / Voice / **Audio**, front/back, portrait + landscape) (§10.2) | 🔁 Phase 3 option (webcam) | 🔁 Phase 3 option (webcam) | ✅ | ✅ |
| Read mode: full-screen prompter without camera (glass rigs, tablets on stands) (§7.2) | — (overlay instead) | — (overlay instead) | ✅ | ✅ |
| Notch placement | ✅ (notched Macs; top-center dock elsewhere) | 🔁 "Top-center dock" (next to webcam) | — | — |
| Corner placement + snap | ✅ | ✅ | — | — |
| Click-through | ✅ | ✅ (`WS_EX_LAYERED \| WS_EX_TRANSPARENT`) | — | — |
| **R1: hidden from screen sharing / recording** (on by default) | ✅ best-effort (`sharingType = .none`) | ✅ best-effort (`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, Windows 10 2004+) | — not needed: the overlay is app UI and is **never in the recorded video** | — same as iOS |
| Multi-display memory | ✅ | ✅ | — | — |
| Analytics events | ✅ | ✅ | ✅ | ✅ (+ web site) |
| Paywall + cross-device Pro | ✅ | ✅ | ✅ | ✅ |

**Product implication:**
- The marketing site and in-app copy must describe features per platform. They must not claim "invisible everywhere".
- UI for unsupported features is **hidden** on that platform, never shown disabled without explanation.

---

## 5. Speech recognition strategy

The POC uses Apple's `SFSpeechRecognizer`. The other platforms have no equivalent with the same quality:
- Windows `Windows.Media.SpeechRecognition` has weaker quality and inconsistent word timing.
- Android `SpeechRecognizer` is on-device only on some devices, has session time limits, and gives no word timestamps.

**Plan: bundle one on-device engine on every platform → identical behaviour.**

- **Engine:** [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0, actively maintained, has a Flutter/Dart package, and supports all our targets).
  - **Voice mode:** a streaming transducer model (English, int8, about 20–70 MB) gives partial results as words are spoken, with low latency.
  - **Recorded audio:** a non-streaming/offline model with **token timestamps**, which replaces `SFSpeechURLRecognitionRequest`.
- **Abstraction:** a `SpeechEngine` interface (`Stream<RecognizedWords> listen()`, `Future<List<TimedToken>> transcribeFile(path)`). Implementations:
  - `SherpaSpeechEngine` (default, all platforms)
  - `AppleSpeechEngine` (optional, macOS/iOS: `SFSpeechRecognizer` or `SpeechAnalyzer` on OS 26+) used **only if** benchmarks show it is clearly better
- **Languages:** **English only at launch.** The English model is bundled so the app works offline on first launch. Later languages are optional in-app downloads, one model per language. They are selected in Settings, and the language is stored per script.
  - The tokenizer and `normalize()` are built language-aware from day one: Unicode-aware, with no ASCII-only assumptions. Adding a language then means adding a model, not rewriting the matcher.
- **Mic capture:** `record` package or a small native capture (16 kHz mono PCM) feeding sherpa. Normal mode **must never open the microphone**. This is enforced in the `AudioInput` service with a unit test.
- **Benchmark gate (Phase 0):** compare sherpa against Apple on 10 recorded scripts (word error rate, latency, CPU, RAM). Targets: WER ≤ Apple + 3 points, partial-result latency ≤ 300 ms.

Licence check: the model weights must also allow commercial use. Several sherpa zipformer models are Apache-2.0. Each one we ship is recorded in `THIRD_PARTY_NOTICES`.

---

## 6. Target architecture

### 6.1 Repository layout

```text
TelePrompterApp/
├── web/                         # UNCHANGED apart from GA (Next.js marketing site, Netlify base = web)
├── app/                         # NEW: Flutter application (flutter create --platforms=macos,windows,ios,android)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/                # pure Dart, no Flutter imports → fully unit-testable
│   │   │   ├── script/          # Script, tokenizer, normalize() (single copy, Unicode-aware)
│   │   │   ├── matching/        # port of follow()/hasPhraseConfirmation/align()/pacingCeiling
│   │   │   ├── progress/        # PromptReadingProgress
│   │   │   ├── entitlements/    # paywall state machine (pure Dart, injectable clock) (§10.4)
│   │   │   └── settings/        # typed settings + persistence keys
│   │   ├── services/            # interfaces + impls
│   │   │   ├── speech/          # SpeechEngine, SherpaSpeechEngine, AppleSpeechEngine
│   │   │   ├── audio/           # AudioInput (mic), AudioPlayback (file)
│   │   │   ├── storage/         # ScriptLibrary (.txt files + JSON index), POC migration
│   │   │   ├── window/          # PrompterWindow facade over echoprompt_window (desktop)
│   │   │   ├── camera/          # VideoRecorder facade over echoprompt_camera (mobile) (§10.2)
│   │   │   ├── account/         # optional sign-in (Supabase Auth)
│   │   │   ├── billing/         # RevenueCat + Paddle checkout + backend token client
│   │   │   ├── analytics/       # AnalyticsService + Firebase / Measurement Protocol sinks (§10.1)
│   │   │   └── permissions/
│   │   ├── features/
│   │   │   ├── studio/          # editor, history picker, settings cards
│   │   │   ├── prompter/        # desktop floating prompter: full / compact / notch layouts
│   │   │   ├── read/            # mobile Read screen (full-screen, no camera)
│   │   │   ├── video/           # mobile Record screen, R2 (camera + floating prompter overlay)
│   │   │   └── paywall/         # paywall, restore, account screens
│   │   └── ui/                  # theme, shared widgets
│   ├── test/                    # unit + golden + matcher regression + entitlement tests
│   ├── integration_test/
│   ├── macos/ windows/ ios/ android/   # Flutter runners (macOS has two flavours: direct, mas)
│   └── pubspec.yaml
├── packages/
│   ├── echoprompt_window/       # NEW: desktop window tricks
│   │   ├── lib/                 # Dart API
│   │   ├── macos/   (Swift)     # NSWindow level, notch frame, sharingType, ignoresMouseEvents, Spaces
│   │   └── windows/ (C++)       # HWND_TOPMOST, WDA_EXCLUDEFROMCAPTURE, WS_EX_TRANSPARENT, monitors
│   └── echoprompt_camera/       # NEW (Stage 2): camera + mic capture shared with speech recognition
│       ├── ios/     (Swift)     # AVCaptureSession → AVAssetWriter + audio tap for the speech engine
│       └── android/ (Kotlin)    # CameraX / MediaCodec + AudioRecord tap for the speech engine
├── backend/                     # NEW (Stage 2): Supabase project (SQL migrations + Edge Functions) (§10.4)
├── legacy/macos-poc/            # Swift POC moved here at parity (Phase 4)
├── plan/                        # this document
└── .github/workflows/           # CI build matrix
```

### 6.2 Key packages (mature, cover all our platforms unless noted)

| Need | Package |
|---|---|
| State | `flutter_riverpod` |
| Mic PCM capture | `record` (stream mode) |
| Audio file playback with precise position | `just_audio` (+ `just_audio_media_kit` on Windows) |
| Speech | `sherpa_onnx` |
| File picker | `file_picker` |
| Paths / settings | `path_provider`, `shared_preferences` |
| Permissions (mobile) | `permission_handler` |
| Keep screen awake | `wakelock_plus` |
| Desktop window basics | `window_manager` (size, position, always-on-top, frameless), extended by `echoprompt_window` |
| Crash reporting | `sentry_flutter` (**opt-in**, no script content ever sent) |
| Account / backend (Stage 2) | `supabase_flutter` (Auth with Apple, Google, and email magic link; works on all four OSes over HTTP) |
| IAP (Stage 2) | `purchases_flutter` (RevenueCat) on iOS, macOS (Mac App Store flavour), and Android. The direct macOS build and the Windows build use Paddle checkout, with entitlements read through the backend. |
| Analytics (Stage 2) | `firebase_analytics` (iOS, Android, macOS); a small Dart GA4 Measurement Protocol client (Windows) |
| Secure storage (Stage 2) | `flutter_secure_storage` (Keychain, Android Keystore, Windows DPAPI) for entitlement tokens and the free-script counter |
| Connectivity (Stage 2) | `connectivity_plus` runs the subscription check as soon as the device is back online |
| Camera preview (Stage 2) | Our own `echoprompt_camera` renders into a Flutter `Texture`. The stock `camera` package can't share the mic with speech recognition. |

### 6.3 Invariants carried over from the POC

1. A **presentation session ID** is regenerated on every "Start". It is the only signal that resets scroll, highlighting, and playback.
2. **Normal mode never touches the microphone.**
3. **Matching is conservative:** falling behind is preferred to skipping ahead.
4. Placement changes must **not** rebuild the prompter widget tree, so the reading position is kept.
5. Starting the prompter saves the script.
6. Scripts are readable `.txt` files in a user-visible folder:
   - macOS (direct) and Windows: `~/Documents/EchoPrompt Scripts`
   - macOS (Mac App Store): see the sandbox note in §9.1
   - iOS: app Documents, exposed in the Files app
   - Android: app-specific storage plus export/import through the Storage Access Framework

### 6.4 Performance and stability budgets (checked in CI and manual QA)

| Metric | Target |
|---|---|
| Cold start to Studio (desktop / mid-range phone) | < 1.0 s / < 1.5 s |
| Idle RAM, Normal mode (desktop) | < 150 MB |
| RAM in Voice mode (model loaded) | < 300 MB |
| Scrolling | Steady 60 fps (120 fps on ProMotion / 120 Hz Android), no dropped frames in a 10-minute script |
| Voice word-to-highlight latency | < 300 ms p95 |
| CPU in Voice mode | < 25% of one core (Apple M1 / Snapdragon 8-class) |
| Record screen, R2 (1080p + Voice or Audio) | 10 minutes on a Pixel 7a / iPhone 12 with no dropped prompter frames and no thermal throttling |
| Crash-free sessions | ≥ 99.8% |
| Installer size | Desktop < 120 MB, mobile < 100 MB (including the English model) |

---

## 7. Engineering approach

### 7.1 Desktop overlay (R1): single-window prompter (macOS, Windows)
- **What the user gets:**
  - a prompter that floats above **any** app (browser, Zoom, OBS, VS Code, PowerPoint), including full-screen Spaces on macOS;
  - hidden from capture by default;
  - Normal, Voice, and Recorded-audio modes, switchable from the overlay itself.
- **Studio config:** normal titled, resizable window.
- **Prompter config:** the plugin switches the same native window to borderless, top-most, transparent background, all Spaces/virtual desktops, hide-from-capture, and click-through. It then applies the placement frame.
- **Close / Esc:** restore the Studio frame and style.
- **macOS specifics:** reuse the POC logic, ported into the plugin:
  - notch frame from `safeAreaInsets` / `auxiliaryTopLeftArea`
  - window level above the menu bar
  - `constrainFrameRect` override (the Flutter `MainFlutterWindow` subclass can override it)
  - per-display frame keys
  - snap-to-corner
- **Windows specifics:**
  - "Notch" placement becomes a **top-center dock** under the webcam.
  - Corner and floating placements behave the same as on macOS.
  - Per-monitor DPI awareness (v2).
  - Capture hiding uses `WDA_EXCLUDEFROMCAPTURE`, available on Windows 10 version 2004 and later. Older builds fall back to "visible" with a notice.

### 7.2 Mobile and tablet (R2): camera with a floating prompter

A phone or tablet can't float a prompter over **other** apps the way a desktop can: iOS doesn't allow it. So on mobile **EchoPrompt itself provides the camera**, and the prompter floats over its preview. After writing a script, the user taps **Record** (the main button) or **Read**:

| | **Record** (R2, primary) | **Read** (secondary) |
|---|---|---|
| What's on screen | Live camera preview filling the screen, with the **floating prompter overlay** docked at the top | Full-screen prompter text only |
| Camera | **Front or back camera**, switchable before recording | None |
| Follow modes | **Normal, Voice, Recorded audio**, all usable while recording (audio routing in §10.2) | Normal, Voice, Recorded audio |
| Orientation | **Portrait and landscape.** The overlay re-lays out at the top in both. | Portrait or landscape, with rotate/mirror toggles |
| Typical use | Talking-head videos (front camera); filming a product or scene while narrating (back camera); voice-over/lip-sync takes paced by a reference recording (Audio mode) | Teleprompter glass rig (mirror on), tablet on a stand, rehearsal |

- Shared behaviour in both: tap a word to jump there, swipe to scroll, two-finger tap to pause, and the screen stays awake.
- On tablets, Studio and a live prompter preview sit side by side.
- **Back camera:** while filming outward, the presenter faces the screen, so the overlay reads naturally. To film *yourself* with the back camera, use a mirror rig (Read + mirror) or the Phase 3 "remote control" idea.
- **Floating over *other* apps' cameras** (Instagram, TikTok) isn't required by R2. It stays a possible later idea (§8 Phase 3), not a commitment.

### 7.3 Testing (none exist today, so they are added from day one)
- **Matcher regression suite:** recorded transcripts (partial-result sequences) + scripts → expected confirmed indices. Run the **Swift POC on the same fixtures** to build the golden expectations, so the Dart port provably behaves the same.
- **Entitlement suite:** pure Dart tests with an injectable clock (§10.4).
- Unit tests for tokenizer, normalisation, history filename rules, settings persistence, and POC migration.
- Golden (screenshot) tests for prompter, Read, and Video layouts in each theme and orientation.
- `integration_test` smoke flow on each platform in CI.
- Manual release checklist: the capture-hiding verification matrix from `.claude/specs/prompter-invisibility-and-placement.md`, extended to Windows, plus purchase and restore on every store.

### 7.4 CI/CD (deferred; build locally)
For a solo developer with manual store uploads, CI is overhead. **Skip for now.** Revisit in Phase 3+ if automated tests are added or if you want a build cache. Local builds and manual uploads are sufficient for Phase 1–2.

---

## 8. Phased roadmap — fast-track approach

Durations assume one full-time developer. Each phase ends with a working build on every platform.

### Phase 1: Build everything (≈8–10 weeks)

Build all functionality across all platforms in parallel:
1. Scaffold `app/`, `packages/echoprompt_window`, and `packages/echoprompt_camera`.
2. Port `core/`: tokenizer, matcher, aligner, progress. Golden fixtures from the POC.
3. Script Studio: editor, history, settings, library, import/export.
4. **Desktop (R1, macOS + Windows):**
   - Prompter overlay: floating, click-through, hidden from capture (best-effort).
   - Layouts: full, compact, notch (macOS).
   - Placements: notch (macOS), corner snap (macOS), floating.
5. **Mobile (R2, iOS, iPadOS, Android):**
   - In-app camera with front/back capture.
   - Floating prompter overlay at the top of the screen.
   - Portrait and landscape with orientation lock during recording.
   - Record screen with timer, camera flip, and 3-2-1 countdown.
6. **All three modes everywhere:** Normal (timer), Voice (live mic + streaming ASR), Recorded audio (file + offline transcription with timestamps).
7. **Audio mode while recording:** auto-detect output device (headphones if connected, otherwise built-in speaker by default), silent pacing (no playback), explicit speaker option.
8. Script persistence: `UserDefaults` on mobile/macOS, Android app storage. **POC migration:** existing macOS users keep scripts and settings via same bundle ID.
9. `Entitlements` interface with "everything unlocked" stub. Script IDs and content fingerprints for paywall later.
10. `AnalyticsService` interface (no-op sink for now); events wired at call sites.
11. Opt-in crash reporting (Sentry). Make it option for the timebeing.

### Phase 2: Manual testing (≈2–3 weeks)

You test every platform, every mode, and match against the POC:
- Desktop overlay behavior on macOS and Windows (placement, click-through, auto-scroll).
- Mobile recording on iOS, iPadOS, and Android (video quality, audio sync, thermal behavior).
- Voice mode: speech recognition latency, matching accuracy.
- Recorded audio: transcription correctness, word timestamps, sync during playback.
- Settings, themes, mirror, rotation.
- Script import/export.
- Identify and fix bugs discovered during testing.

### Phase 3: Analytics + Paywall + Backend (≈4–5 weeks)

1. **Google Analytics:** Firebase on iOS, Android, and macOS; Measurement Protocol on Windows; gtag on the web site.
   - Events from §10.1, with region-based consent.
2. **Paywall logic:** free-script counter (5 scripts max), entitlement state machine (FREE → LOCKED → PRO_ACTIVE / LIFETIME).
   - Script ID and fingerprint validation.
   - 30-day offline limit and advance warning from day 25.
   - Local token storage with signature verification.
3. **Backend (Supabase):** defer exact implementation to Phase 3. We'll discuss your ideas on how to minimize costs before launch.
   - Entitlement token signing (Ed25519).
   - Free-script counter by device and account.
   - Optional cross-device account (Sign in with Apple / Google / email).
   - Analytics proxy for Windows.
4. **License & terms:** replace current `LICENSE` with "All rights reserved", add `TERMS.md` (commercial use allowed), and `THIRD_PARTY_NOTICES`.
5. **Privacy policy:** on-device speech, no script upload, analytics/optional account/backend disclosures. Host on the web site (or standalone, your choice).
6. Create store listings (text, screenshots, privacy labels, data safety).
7. **Audio mode soundtrack (native):** write the chosen audio file as the video's own audio track in `packages/echoprompt_camera` (iOS `AVAssetWriter`, Android `MediaCodec`/`MediaMuxer`), replacing the interim Speaker route so the recorded sound is clean regardless of the room (§10.2).

### Phase 4: Polish + Release (≈2–3 weeks)

1. Final polish and bug fixes from Phase 2 and 3.
2. Store submissions:
   - **macOS:** Mac App Store (sandboxed build).
   - **Windows:** Microsoft Store (MSIX).
   - **iOS / iPadOS:** App Store (Universal Purchase shared with macOS).
   - **Android:** Google Play.
3. All under personal developer accounts (Apple, Google, Microsoft).
4. Move the Swift POC to `legacy/macos-poc/`.
5. Update `CLAUDE.md`, `README.md`, and build-script references.

### Phase 5 (optional, later): Business formalisation

Start this **only once EchoPrompt earns real money**. Suggested triggers:
- revenue reliably above roughly €1,000/month;
- a B2B/OEM deal;
- wanting to hire.

Everything is listed in §9.5. The product and code don't change, because store accounts can be migrated to a company later.

---

## 9. Distribution and monetisation readiness

These decisions affect Phase 1 code, which is why they appear now.

### 9.1 Channels

| Platform | Channels at launch | Billing | Signing / packaging |
|---|---|---|---|
| macOS | **Mac App Store only** | App Store (StoreKit through RevenueCat). Universal Purchase shared with iOS. | App Sandbox, store updates. |
| Windows | **Microsoft Store** (free individual account) | Paddle checkout in the browser + account sign-in. The Store allows third-party payments for non-game apps. | **The Microsoft Store signs the package**, so no paid code-signing certificate is needed and there are no SmartScreen warnings |
| iOS / iPadOS | App Store | App Store (RevenueCat). Universal Purchase shared with macOS. | Apple Developer Program |
| Android | Google Play | Google Play Billing (RevenueCat) | Play App Signing; declare mic, camera, and later overlay permissions |

**macOS specifics (Mac App Store):** App Sandbox is on. Entitlements: `audio-input`, `files.user-selected.read-write`, `network.client`. Scripts folder is inside the app container by default; user can choose any folder once (security-scoped bookmark). **POC migration:** existing users keep their scripts via the same bundle ID (`com.echoprompt.app`) in `UserDefaults`.

**Accounts and costs for launch (all as an individual):**
- Apple Developer Program, **Individual**: $99/yr, covers iOS + macOS.
- Google Play, **personal account**: $25 one-time.
- Microsoft Store, individual account: free.
- Paddle: no monthly fee, a percentage per sale (Windows only).
- RevenueCat: free up to a revenue threshold.
- Supabase: free tier, **EU region** (Frankfurt).
- Firebase/GA4: free.

**Total fixed cost to launch: about $125 in the first year (Apple $99 + Google Play $25 + domain optional).** Privacy policy and terms can be pages on the existing Netlify site.

### 9.2 Launching as an individual (now) and app IDs

**Build and sell first; formalise later.** All stores accept individual developers. Apple, Google, Microsoft, and Paddle (for Windows) act as the **seller to the customer** and collect and pay consumer VAT/sales tax worldwide, so a company isn't needed to start. Store accounts can be moved to a company later (Phase 5).

**What launching as an individual means in practice (the few unavoidable items):**
1. **Your name is the seller name** on the store listings. Because you sell paid apps in the EU, Apple and Google also require the EU "trader" declaration, which **publicly shows your address, phone number, and email** on EU store pages (Digital Services Act). Use a dedicated email and phone number. This is the main privacy trade-off of skipping the company for now.
2. **Google Play personal accounts** must run a **closed test with at least 12 testers for 14 days** before the first production release. Recruit the testers (friends, early users) during Phase 2, so this doesn't delay launch.
3. **Apple Small Business Program:** enroll as soon as the developer account exists (free). Apple's commission drops from 30% to **15%**. Google is already 15% on subscriptions and on the first $1M a year.
4. **Tax on your income (Portugal):** before the first payout, open self-employed activity (*início de atividade*, category B, simplified regime) on the Portal das Finanças. It is free and online. Income is declared in your yearly IRS return. Store sales are B2B payouts to you, and they collect the consumer VAT. Check your VAT position (small-business exemption) on the portal when you open the activity, or with a one-off accountant consultation once money arrives.
5. **Paddle (Windows only)** verifies your identity and website before approving payouts for the Windows build through Paddle checkout.

**App ID: keep `com.echoprompt.app` everywhere.** It is already the POC's bundle ID, so:
- existing macOS users upgrade in place (same `UserDefaults` domain, same scripts);
- iOS, iPadOS, and the Mac App Store app share it, which enables **Universal Purchase** (one App Store purchase for iPhone, iPad, and Mac);
- the Android `applicationId` is `com.echoprompt.app`;
- the Windows MSIX identity is assigned when the app name is reserved in the Microsoft Store;
- Firebase, RevenueCat, and Supabase projects are named `echoprompt-prod` and `echoprompt-dev`.

**Reserve the IDs early.** It's free with the developer accounts:
- register the bundle ID in the Apple Developer portal;
- create the Play Console app and reserve the Microsoft Store app name.
- Bundle and application IDs are first-come and **can never be changed** after release without losing users and purchases.

**Before reserving:** do a free 10-minute name check for "EchoPrompt" in TMview (EU) and USPTO search. Filing a trademark is Phase 5.

### 9.3 Paywall architecture
The full design is in §10.4. Store rules that shape it:
- iOS, iPadOS, Mac App Store, and Android purchases **must** use store billing. Exception: since 2025, US iOS apps may also link to a web purchase.
- Cross-device Pro is allowed by Apple's multiplatform-services rule: Pro bought on Windows can unlock iOS, **as long as** the iOS app also sells Pro through in-app purchase, which it does.
- Windows can use **Paddle as merchant of record** for direct sales outside the Microsoft Store (Phase 5). Paddle collects and pays global VAT and sales tax for you.

### 9.4 Launch checklist (v1, minimal; these are store requirements, not optional)
- [ ] Replace the current **"Personal Use"** `LICENSE`, add `TERMS.md`, and make the app source private (§10.3).
- [ ] `THIRD_PARTY_NOTICES` for Flutter (BSD), packages, sherpa-onnx, and model weights. Verify each model's licence allows commercial use.
- [ ] **Privacy policy**, required by every store. It must state on-device speech processing and no script upload, and disclose:
  - Google Analytics;
  - the optional account (email);
  - the backend (device-ID hash, purchase status);
  - camera, microphone, and photo access.

  Host it, with the terms, as `/privacy` and `/terms` pages on the existing Netlify site. That is a small `web/` addition, made only with your go-ahead; a standalone hosted page is the alternative.
- [ ] App Store privacy "nutrition label" and Play Data Safety form. Declare "Usage data → Analytics" (not linked to identity, not used for tracking) and "Email" (account, optional).
- [ ] Account deletion inside the app, which Apple and Google require when sign-up is offered.
- [ ] Analytics consent in the app, plus a cookie/consent banner on the web site for GA in the EEA/UK (Google Consent Mode v2). GDPR applies because you are in the EU, and this is its practical minimum.
- [ ] Accessibility basics: VoiceOver/TalkBack labels and Dynamic Type, which App Review checks.
- [ ] The individual-launch items in §9.2: trader declaration, Play's 12-tester closed test, Apple Small Business Program, and opening activity at Finanças before the first payout.

### 9.5 Later (Phase 5, optional): business formalisation
Do these **once EchoPrompt is earning**, typically above roughly €1,000/month, or before a B2B deal. None of them changes the app.

| Item | Why / when |
|---|---|
| **Portuguese company** (*Unipessoal Lda*, through Empresa na Hora, about €360) plus a *contabilista certificado* (about €100–250/month) | Limits personal liability, and puts the company instead of your personal details on the store listings. Worth it once revenue covers the accountant. |
| **Move store accounts to the company** | Apple supports converting an individual membership to an organisation, and Google Play and Microsoft support app transfers between accounts. Users and purchases are kept, and the bundle IDs stay the same. Needs a **D-U-N-S number** (free, 1–2 weeks). |
| **Lawyer-reviewed EULA** (Portuguese law, Portuguese-language version, EU Digital Content Directive wording) and **business/OEM licence** | Once there are B2B customers or meaningful consumer volume |
| **Portuguese consumer-law items** (e.g. Livro de Reclamações Eletrónico and dispute-resolution information on the site) | The lawyer confirms which apply. While the stores and Paddle are the sellers of record, most consumer obligations sit with them. |
| **Full GDPR paperwork:** record of processing, processor agreements (Google, Supabase, RevenueCat, Paddle, Sentry), a written data-request process | As the user base grows. The v1 privacy policy and consent already cover the basics. |
| **EU trade mark** (EUIPO, about €850, class 9) | Once the name has proven value worth protecting |
| **Direct Windows download** with a code-signing certificate | Only if users ask for it outside the Microsoft Store |

---

## 10. Stage 2 requirements

Stage 2 is the same as roadmap Phase 2 (§8). Phase 1 already builds the interfaces it plugs into (`AnalyticsService`, `Entitlements`, stable script IDs and fingerprints).

### 10.1 Google Analytics (all apps + web site)

**Goal:** measure how many people try the app (they press **Start teleprompter**) and how many of those convert to paying. Do it with the same event names on every platform, so one GA4 property can compare them.

#### Setup

| Surface | How events reach GA4 |
|---|---|
| iOS, iPadOS, Android, macOS (both flavours) | `firebase_analytics` (Firebase *is* GA4 for apps). One Firebase project, with one app stream for each platform. |
| Windows | Firebase has no Windows SDK, so Windows uses the **GA4 Measurement Protocol**. Events go through our backend (`/events` Edge Function), so the GA `api_secret` never ships inside the app. |
| Web site (`web/`) | `@next/third-parties/google` `<GoogleAnalytics>` in `layout.tsx`, plus a tiny client component that sends a click event for links marked `data-ga-event`. `page.tsx` **stays a Server Component**, and the page still works with JavaScript disabled. |

- **One property, many streams.** Every event carries:
  - `platform`: macos|windows|ios|ipados|android|web
  - `app_version`
  - `channel`: app_store|mac_app_store|mac_direct|win_store|play|web
- **Dart side:** one `AnalyticsService.log(AppEvent)` with typed event classes. A sink is chosen per platform: `FirebaseSink`, `MeasurementProtocolSink`, or `NoopSink` when the user hasn't consented. Events are queued while offline.
- **Naming rules:** GA4 event names may contain only letters, numbers, and underscores. Your suggested `mic-start` therefore becomes `mic_start`, and so on. GA4 limits: 40 characters per name, 25 parameters per event, 500 distinct event names.

#### Privacy rules (these protect the "private, on-device" promise)
- **Never** send script text, script titles, file names, transcripts, audio, video, or account email. Lengths are sent only as buckets (`<100`, `100–500`, `500–2k`, `2k+` words).
- No advertising ID: set `GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED = false` on iOS and remove the `AD_ID` permission on Android. With that, iOS **doesn't need an ATT prompt**.
- **Consent (decided: region-based):**
  - EEA, UK, and Switzerland: analytics is opt-in.
  - Elsewhere: analytics is on by default, with a clear switch in Settings ("Share anonymous usage statistics").
  - The web site uses Consent Mode v2.
  - The opt-in rule follows the **user's** location, because ePrivacy consent law applies where the device is. GDPR duties (privacy policy, processor agreements, data rights) apply to **all** users, because the company is in Portugal (§9.4).

#### Event catalogue

★ marks your requested events, renamed for GA4.

| Event | When it fires | Key parameters | Answers |
|---|---|---|---|
| `first_open` / `app_open` | automatic (Firebase); sent manually on Windows | — | Install and active-user base |
| `script_created` | First save of a new script | `words_bucket`, `source` (typed\|pasted\|imported) | Are people bringing real scripts? |
| `script_loaded` / `script_deleted` / `script_exported` | History actions | — | Library usage |
| ★ `teleprompter_start` | **Start teleprompter** (desktop) or **Read** (mobile) pressed and allowed | `mode` (normal\|voice\|audio), `surface` (floating\|read\|video), `placement`, `words_bucket`, `free_scripts_used` | **Trial volume, the top of the funnel** |
| `teleprompter_complete` | Reached the end of the script | `mode`, `duration_s` | Did it actually work for them? |
| `teleprompter_exit` | Closed before the end | `mode`, `duration_s`, `progress_pct` (rounded to 10s) | Where people drop off |
| `teleprompter_restart` | Restart pressed | `mode` | Rehearsal behaviour |
| `mode_change` | Normal/Voice/Audio switched | `from`, `to` | Which mode sells the product |
| ★ `mic_start` | Microphone listening begins (Voice mode, or video + voice) | `mode`, `surface` | Voice adoption |
| ★ `mic_stop` | Listening ends | `duration_s`, `reason` (user\|end\|error\|interrupted) | Voice reliability |
| `permission_result` | OS permission answered | `permission` (mic\|speech\|camera\|photos), `granted` | Permission drop-off |
| `speech_error` | Recognizer failure | `code`, `engine` | Quality monitoring |
| ★ `setting_change` (your "settings-toggle") | A setting changes. Sliders send one event on release. | `setting` (font_size\|line_spacing\|speed\|theme\|mirror\|opacity\|placement\|click_through\|hide_from_capture\|analytics\|language), `value` (enum/bool/rounded number only) | Which settings matter |
| `video_mode_enter` | Video screen opened | `orientation` | Video interest |
| ★ `video_record_start` | Record pressed | `orientation` (portrait\|landscape), `camera` (front\|back), `prompter_mode`, `resolution` | Video adoption |
| ★ `video_record_stop` | Recording stopped | `duration_s`, `orientation`, `reason` (user\|interrupted\|storage_full\|error) | Recording reliability |
| `video_saved` | File written to Photos/gallery | `duration_s` | Successful outputs |
| ★ `video_mode_exit` | Video screen closed | `recordings_count` | Session outcome |
| `free_limit_reached` | The user tries to use a 6th script | — | **Conversion point** |
| `paywall_view` | Paywall shown | `trigger` (script_limit\|subscription_expired\|offline_verification\|manual) | Paywall reach |
| `purchase_start` | User taps a plan | `product` (monthly\|lifetime), `highlighted` (bool) | Plan preference |
| `purchase` (GA4 standard event) | Purchase confirmed | `product`, `value`, `currency`, `store` (app_store\|play\|paddle) | **Revenue, conversion rate** |
| `purchase_cancel` / `purchase_fail` | Purchase flow aborted or failed | `product`, `reason` | Checkout friction |
| `restore_purchases` | Restore pressed | `success` | Support load |
| `sign_in` / `sign_out` | Account actions (GA4 standard `login`) | `method` (apple\|google\|email) | Cross-device adoption |
| `subscription_check` | Entitlement verification ran | `result` (active\|expired\|grace\|offline_limit\|error) | Billing health |
| `access_blocked` | Start blocked by the paywall | `reason` (limit\|expired\|offline_limit) | Churn |
| **Web:** `download_click` | Any download/store button | `platform`, `location` (nav\|hero\|footer\|download_section) | Site → download conversion |
| **Web:** `cta_click` | Other CTAs ("See modes", etc.) | `label`, `location` | Page engagement |
| **Web:** `outbound_click` | YouTube/GitHub links | `destination` | — |

**Funnels to build in GA4 (Explorations):**
1. Web: `page_view` → `download_click`.
2. App: `first_open` → `script_created` → `teleprompter_start` → `teleprompter_complete`.
3. Monetisation: `free_limit_reached` → `paywall_view` → `purchase_start` → `purchase`.

Attribution from the web site to the app store uses UTM-tagged store links (App Store campaign tokens, Play Install Referrer) and a `?ref=` parameter on direct desktop downloads.

**Mark as key events (conversions):** `teleprompter_start`, `purchase`, `download_click`.

### 10.2 Camera + floating prompter overlay (R2: iOS, iPadOS, Android)

**Requirement (R2):** on iOS, iPadOS, and Android phones and tablets, the app's own camera (**front or back**) records video while a **floating prompter overlay** runs on top of the preview, **at the top of the screen**, in both **portrait and landscape**. All three modes are available: **Normal, Voice-controlled, and Recorded audio**. Desktop webcam recording is Phase 3 (decided).

#### UX
- **Entry point:** the **Record** button in the Studio (primary), next to **Read** (§7.2).
- **Camera preview:** fills the screen. Front camera by default; a flip button switches cameras before recording.
- **Floating prompter overlay** docked to the top edge, placed below the notch, Dynamic Island, or status bar (safe-area aware):
  - Default height: 30% of the screen in portrait, 40% in landscape.
  - The height can be dragged and is remembered separately for each orientation.
  - Adjustable background opacity so the user can still see themselves.
- **Why the top:** it keeps the presenter's eyes close to the front lens. On phones held in landscape, the lens sits at a *side* edge. The strip is still at the top as specified, and a later "dock near camera" option can move it.
- **Rotation:** the preview and prompter re-layout when the device rotates before recording. **Orientation is locked while recording**, so the file has one orientation. The lock is released on stop.
- **Controls:** record/stop with a timer, camera flip (disabled while recording), prompter mode (**Normal / Voice / Audio**), speed, font size, pause scrolling, and a 3-2-1 countdown option.
- **What the recording contains:**
  - The prompter is **not** in the video; it is a UI overlay only.
  - Front-camera video is saved un-mirrored, like the system Camera app.
- **Prompter modes while recording:**
  - **Normal:** timer scrolling starts when recording starts, after the countdown.
  - **Voice:** follows the presenter's speech, using the same mic stream that records the video (see Technical design).
    - If speech is heard but does not match the script for ~4 s, the status shows **Lost your place**. Repeating the last phrase recovers; tapping a word also moves the highlight there. The matcher never skips ahead on its own.
  - **Recorded audio:** see the next section.

#### Recorded-audio mode while recording (resolves the playback-vs-microphone conflict)
Use case: the presenter has a reference recording, such as a guide narration or their own earlier take, and wants the prompter paced by it while they record a new video.

The conflict: if the reference audio plays from the phone's speaker, the microphone records it into the video. The fix is a setting, **"Reference audio plays through"**:

| Option | When it's the default | What happens |
|---|---|---|
| **Headphones** | When wired or Bluetooth headphones are connected | The presenter hears the reference audio; the microphone doesn't pick it up. Input stays on the **built-in mic**, so Bluetooth output keeps full quality. iOS: `setPreferredInput(builtInMic)`. Android: `AudioRecord.setPreferredDevice(builtin mic)`. |
| **Silent pacing** | When no headphones are connected | The audio is **not played**. The prompter scrolls on the reference file's word timeline, which works like a precise clock. The recording stays clean. |
| **Speaker** | Never; it must be chosen explicitly | Plays out loud, with a warning that it will be audible in the video |

- **Preparation:** the reference file is transcribed on-device **before** recording, with a progress bar. The word timestamps are cached against the file's hash, so the next take starts instantly.
- **Sync:** playback, or the silent timeline, starts on the **first recorded video frame** after the countdown. Drift is corrected against the media clock, the same `pacingCeiling` logic as the POC.
- **Product decision (updated):** in Audio mode the recorded video **must contain the audio file's sound**, and the prompter text doubles as a look-ahead cue (the current line plus the next 1-2 lines) so the presenter can act early, e.g. turn the camera toward the river before the narration reaches it. The Studio's Record button is the primary action for Voice and Audio; Normal uses Read (no camera or microphone). See `plan/mobile-ux-plan.md`.
  - **Interim (implemented):** Audio mode defaults to the **Speaker** route, so the microphone records the playback into the video. Quality depends on speaker volume and room acoustics.
  - **Target (not started; scheduled in Phase 3, item 7):** write the audio file as the video's own audio track in the native encoder (`packages/echoprompt_camera`, iOS `AVAssetWriter` and Android `MediaCodec`/`MediaMuxer`), so the soundtrack is clean regardless of the room. Headphones then work for the presenter without affecting the video.
- **Saving:**
  - iOS: Photos (add-only permission).
  - Android: `MediaStore` (DCIM/EchoPrompt).
  - Both: a copy in app storage, with a share sheet.
- **Interruptions:** a phone call, the app going to the background, low storage, or thermal critical state each **stop and save** what has been recorded so far.
- **Formats:** default 1080p30 H.264/AAC. 4K and HEVC are options on capable devices.

#### Technical design
There are two hard parts:
- **Voice mode needs the mic at the same time as the video recorder.**
- **Audio mode needs playback and recording at the same time**, with playback routed to headphones while the input stays on the built-in mic.

The stock Flutter `camera` plugin takes the mic exclusively and doesn't control audio routing, so we build `packages/echoprompt_camera`:

| | iOS / iPadOS | Android |
|---|---|---|
| Capture | `AVCaptureSession` with video and audio *data outputs* | CameraX (`Preview` + video frames) |
| Encoding | `AVAssetWriter` (H.264/HEVC + AAC) | `MediaCodec` encoders + `MediaMuxer`, fed by one `AudioRecord` |
| Speech | The same audio sample buffers are resampled to 16 kHz mono → `SpeechEngine` | The same `AudioRecord` PCM is resampled → `SpeechEngine` |
| Audio session | `.playAndRecord`, mode `.videoRecording`, options `.allowBluetoothA2DP` (headphone output), preferred input = built-in mic | Foreground service type `camera|microphone` while recording; `AudioRecord` preferred device = built-in mic; reference playback through `AudioTrack`/ExoPlayer routed to headphones |
| Preview to Flutter | `FlutterTexture` (zero-copy `CVPixelBuffer`) | `SurfaceTexture` through the Flutter texture registry |

- One mic stream feeds both the video file and the speech engine. Audio and video stay in sync, and there is no OS conflict over the microphone.
- **Phase 0 spike 5** validates all three modes while recording, including headphone playback with built-in-mic input, before we commit. Fallback on Android: CameraX `VideoCapture` without audio, plus our own AAC track, remuxed by timestamp on stop.
- **Permissions:** camera, microphone, photo-library add (iOS), and `READ_MEDIA_VIDEO` only if we show past recordings.

### 10.3 Commercial licence

Today's `LICENSE` is a *Personal Use* licence that **forbids commercial use**. It blocks both selling the app and customers using it for business.

**For launch (v1): keep it simple, with no lawyer and no company needed.**

| Document | Purpose | Key terms |
|---|---|---|
| `LICENSE` (repository / source code) | Protects the **source code** | "Proprietary — All rights reserved". Replaces the Personal Use text. One paragraph. |
| `TERMS.md` (simple end-user terms, linked in the app, the paywall, and the store listings) | What a user may do with the **app** | Use the app for **personal and commercial purposes**, on the **free tier and on Pro** (decided). **Users own their scripts and the videos/audio they produce.** No reverse engineering, resale, or redistribution of the app. Subscriptions and refunds are handled by the App Store, Google Play, or Paddle. Warranty disclaimer. Mandatory consumer rights are unaffected. |
| Store EULA | Legal terms on the stores | **Apple:** use Apple's **standard EULA** (no upload needed), with `TERMS.md` linked from the paywall. **Google Play / Microsoft Store:** link `TERMS.md`. |

v1 actions:
- [ ] **Make the app source private.** The site links to a public GitHub repo (`arjun2010-ece/EchoPrompt`); anyone could otherwise build it without the paywall. Releases can still be hosted publicly. This costs nothing and protects revenue.
- [ ] Replace `LICENSE` and add `TERMS.md`, plus `THIRD_PARTY_NOTICES` (required by the BSD, Apache, and MIT licences we use).

**Later (Phase 5, once it earns money):**
- a lawyer-reviewed **EULA** (Portuguese law, Portuguese-language version, EU Digital Content Directive wording);
- a **business/OEM licence** (`COMMERCIAL-LICENSE.md`) for companies that want to embed or bulk-license EchoPrompt.
See §9.5.

### 10.4 Paywall

#### Business rules (your requirements + answers 1, 7, 8, 9)

| Rule | Exact behaviour |
|---|---|
| **Free tier** | Free users may present **up to 5 different scripts**, each as often as they like, which allows retakes and rehearsals. A script counts the first time it is **presented** (Start / Read / Video), identified by its script ID. Deleting a script **does not** give the slot back. Rewriting a counted script into a different one (more than 50% of its words changed, detected by the content fingerprint) counts as a new script, which closes the "edit script #1 forever" loophole. **Decided:** re-runs are allowed (`freeScriptRerunsAllowed: true`). Retakes are central to video; blocking a second take feels punishing and hurts trust right before the paywall. The fingerprint rule prevents abuse. It can be tightened remotely later. |
| **After the free limit** (answer 7) | **Start teleprompter, Read, and Record are blocked.** Pressing them opens the paywall. Still allowed: open the app, **read, write, edit, and export** scripts, settings, sign in, restore purchases. |
| **Plans** (answer 1) | **Monthly: €6.99 / $6.99, highlighted as the default.** **Lifetime (one-time purchase): €59.99 / $59.99**, shown next to it. See "Pricing" below. |
| **Lifetime** | Unlocks everything permanently, and the paywall never shows again on that account. Online checks only catch refunds and chargebacks, and **it never needs to be online**. |
| **Monthly subscription** | Unlocks everything while paid. Verified on every launch and once a day while online. **It must be verified at least once every 30 days.** |
| **Offline limit** (answer 8) | A subscriber can stay offline for at most **30 days since the last successful verification**. After that, the paywall shows ("Connect to the internet to confirm your subscription"), even though the device is offline. The moment the device reconnects, the app checks automatically. Paid → unlocked again for 30 more days. Not paid → stays blocked with "Renew to continue". |
| **Advance warning** | A banner shows from day 25 offline: "Connect within N days to keep using EchoPrompt Pro". |
| **Live sessions** | A block **never interrupts** a running prompter or recording. It applies when that session ends, and the recording is always saved. |
| **Cross-device** (answer 9) | One Pro purchase unlocks **all of the user's devices** (up to 5 active at once) when they sign in to an EchoPrompt account. Details below. |

#### Entitlement state machine

```text
                            ┌───────────── verify OK (paid) ─────────────┐
                            ▼                                             │
 FREE (scripts < 5) ──6th script──► LOCKED ──purchase / restore──► PRO_ACTIVE
                                      ▲                         (verifiedAt; validUntil = verifiedAt + 30d)
                                      │                                   │
                                      │              online: verify on launch + daily
                                      │                                   │
                                      ├──── verify says NOT paid ─────────┤
                                      │                                   │ now ≥ validUntil and offline
                                      │                                   ▼
                                      │                     NEEDS_VERIFICATION (paywall: "connect to continue")
                                      │                                   │ connectivity regained → verify
                                      └──── NOT paid ◄────────────────────┤
                                                       paid ──────────────┘ → PRO_ACTIVE

 PRO_LIFETIME: terminal, offline forever; only a refund/chargeback seen online returns it to LOCKED.
```

Implementation notes:
- **Signed entitlement token.** Every successful verification returns a token from the backend, signed with Ed25519: `{userOrDeviceId, entitlement:"pro", product, status, verifiedAt, validUntil, serverTime}`. The app verifies the signature with an embedded public key and stores the token in secure storage, so editing local files can't fake Pro. `validUntil` is always ≤ `serverTime + 30 days`.
- **Store grace periods count as paid.** Apple and Google billing-retry grace periods mean "paid", so a user isn't locked out because their card renewal is being retried.
- **Clock tampering.** The app stores the last trusted `serverTime` and the highest local time it has seen. If the device clock is set backwards by more than 24 h, or is earlier than the last server time, the state becomes `NEEDS_VERIFICATION`. This stops "set the date back" from extending the 30 days.
- **Backend outage.** A user whose token is still valid keeps working (fail open until `validUntil`). An outage can't lock out paying users early.
- **Remote configuration**, with defaults compiled in:
  ```json
  { "freeScriptLimit": 5, "freeScriptRerunsAllowed": true, "rewriteCountsAsNewPct": 50,
    "verifyIntervalDays": 30, "maxOfflineDays": 30, "offlineWarningDays": 5,
    "offerings": ["monthly", "lifetime"], "defaultHighlighted": "monthly", "maxActiveDevices": 5 }
  ```
  Prices are set in App Store Connect, Play Console, and Paddle. RevenueCat shows the user's local currency.

#### Pricing (decided; can be revisited at any time)

| Plan | Price (EUR base / USD) | What you keep after store fees and VAT* | Why |
|---|---|---|---|
| **Monthly** (default, highlighted) | **€6.99 / $6.99** | about **€4.80** per month | At the low end for pro teleprompter apps, so it's an easy "yes" for occasional creators. Low enough that the 5-script trial converts. |
| **Lifetime** | **€59.99 / $59.99** (≈ 8.6× monthly) | about **€41** (App Store/Play) or **€45** (Paddle) | Pays for itself after about 9 months, which suits heavy users and anyone who works offline a lot (they avoid the 30-day check). It is high enough that Monthly stays the natural default. |

\* Rough figures: Portugal's 23% VAT, a 15% store commission (Apple Small Business Program / Google), and Paddle's 5% + $0.50. Net amounts vary by country because VAT rates differ.

- **No separate free trial on the subscription.** The 5 free scripts *are* the trial. One trial mechanism is easier to understand and to enforce.
- **Regional pricing:** set the base in EUR and USD, and let Apple and Google generate the other countries' prices. Lower prices for markets such as India and Brazil can be added later in the store consoles, with no app update.
- **Changing prices later:**
  - Store-console change: new buyers get it at once.
  - Existing subscribers: Apple and Google handle notice and consent for price increases.
  - Lifetime buyers: never affected.
- **Future levers, not in v1:** an annual plan (e.g. €39.99/yr), a launch discount on Lifetime, and A/B price tests with RevenueCat Experiments.

#### Cross-device Pro: optional account (answer 9)

The aim: **pay once, use everywhere**, without forcing a sign-up on people who use one device.

- **No account needed** to try the app or to buy on a store. A purchase on iPhone/iPad/Mac App Store is shared automatically through Universal Purchase and Restore Purchases. On Android it is tied to the Google Play account.
- **With an account** (Sign in with Apple, Google, or email magic link, through Supabase Auth), Pro bought **anywhere** unlocks **every platform**: iPhone → Windows, Android → Mac, Paddle (Windows) → iPad.
  - The RevenueCat `app_user_id` is set to the Supabase user ID, so all purchases attach to that person.
  - **Windows** requires sign-in to buy via Paddle checkout in the browser. The purchase is linked to the account. This replaces licence keys, so there is nothing to lose or copy.
  - Up to **5 active devices** per account. The user can sign out old devices from Settings.
- The free-script counter also follows the account once the user signs in. Signing in on a new device doesn't reset it.
- Apple rules satisfied: Sign in with Apple is offered alongside Google, account deletion is in-app, and Pro is purchasable through in-app purchase on iOS.

#### Free-script counter that survives reinstall
A local counter alone resets on reinstall. Two layers fix that:
1. **On the device:**
   - iOS/macOS: Keychain, which survives reinstall.
   - Android: `ANDROID_ID`, scoped to our signing key and stable across reinstall.
   - Windows: hashed `MachineGuid`.
2. **On the backend:** the counted script fingerprints per device-ID hash, and per account when signed in. The app uses the union of local and server counts. Offline use is counted locally and synced later.

#### Architecture

```text
 iOS / iPadOS / macOS (MAS) ── StoreKit ──┐
 Android ─────────────────── Play Billing ┼──► RevenueCat (entitlement "pro") ──webhooks──┐
 Windows ─────────────────── Paddle checkout ─► Paddle ─► RevenueCat integration ┘
                                                                                  ▼
                    backend/  Supabase, EU region (Auth + Postgres + Edge Functions)
                    • POST /entitlement   → ask RevenueCat for the user's/device's status, return signed token
                    • POST /free-usage    → record counted script fingerprints (device + account)
                    • POST /devices       → register / list / revoke devices (max 5 active)
                    • POST /events        → GA4 Measurement Protocol proxy for Windows (§10.1)
                    • webhooks            → renewals, cancellations, refunds, chargebacks
```

- **Products** (the same IDs on every store):
  - `echoprompt_pro_monthly`: auto-renewing, one month. **Default and highlighted.**
  - `echoprompt_pro_lifetime`: non-consumable on the stores, one-time on Paddle (Windows).
  - Both grant the single entitlement **`pro`**.
- **Store compliance:**
  - Restore Purchases button.
  - Apple's subscription disclosure (price, period, auto-renew, how to cancel, links to Terms and Privacy).
  - Current Play Billing Library.
  - No external purchase links in the Mac App Store and iOS builds, except where regional rules allow them.
- **Testing:**
  - Pure-Dart entitlement tests with an **injectable clock** cover:
    - day 29 vs day 31 offline;
    - reconnect → paid / unpaid;
    - grace period;
    - clock set backwards;
    - lifetime refund;
    - the 6th-script block and the rewrite-fingerprint rule;
    - counter persistence across reinstall;
    - device limit;
    - backend outage.
  - Purchase flows are tested with StoreKit configuration files, Play licence testers, and Paddle sandbox.

---

## 11. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Flutter can't reproduce the macOS notch/top-level panel behaviour (direct or sandboxed) | High | Phase 0 spike 1 is a hard gate. The native plugin has full NSWindow access through `MainFlutterWindow`. |
| Mac App Store review questions the capture-hiding or above-menu-bar window | Medium | Both use public APIs. Describe the feature clearly in review notes. If needed, ship the MAS flavour with the feature off and keep it in the direct build. |
| Capture-hiding changes in a future OS (e.g. ScreenCaptureKit behaviour) | Medium | Best-effort wording, the verification matrix in each release checklist, and per-OS feature flags |
| sherpa-onnx accuracy below Apple's on Mac/iOS | Medium | `SpeechEngine` interface. Use Apple's engine on Apple platforms if it wins the benchmark. |
| Camera recording and speech recognition fight over the mic, or video and audio drift out of sync | High | Our own `echoprompt_camera` with one shared audio stream. Phase 0 spike 5 is a gate, and there is a remux fallback on Android. |
| Thermal throttling (recording + recognition + rendering) on older phones | Medium | Default 1080p30, thermal-state monitoring that lowers resolution or warns, and a 10-minute soak test in QA |
| Audio mode while recording: reference playback leaks into the video, or the Bluetooth mic switch lowers quality | Medium | Headphones / silent pacing / explicit speaker option, with input pinned to the built-in mic (§10.2). Phase 0 spike 5 is the gate. |
| R1 capture hiding fails with a particular recorder | Medium | Best-effort wording, a published support matrix from Phase 0 spike 2, and a re-test every release. On desktop the overlay can also simply be placed outside the captured window or region. |
| Launching as an individual exposes your personal address and phone on EU store pages | Low–Med | Dedicated phone number and email. Move to a company in Phase 5 once revenue justifies it. |
| Matching port subtly differs from the POC | High (core UX) | Golden fixtures generated from the Swift POC, and the port is test-driven |
| The 30-day offline limit locks out a paying subscriber (e.g. a long trip without internet) | Medium | Warning banner from day 25, one-tap verify, clear message, and a support path. Lifetime plan offered for heavy offline users. |
| Paywall bypass (clock rollback, reinstall, script rewriting, building from public source) | Medium | Signed tokens, clock-rollback detection, device and account counters, content fingerprints, and a private repo (§10.3) |
| Backend outage blocks paying users | High | Fail open until the token's `validUntil`, never block during a live session, serverless backend |
| Analytics weakens the "100% private" brand, or breaks GDPR | Medium | No script content is ever sent, no ad IDs, region-based consent, and honest privacy labels. Site copy: "your scripts never leave your device". |
| Model size bloats downloads | Low | int8 quantised English model only. Other languages are optional downloads. |

---

## 12. Decisions log (your answers)

| # | Question | Your answer | Applied in |
|---|---|---|---|
| 1 | Price points / default plan | **Monthly highlighted as the default.** Prices delegated → **Monthly €6.99 / $6.99, Lifetime €59.99 / $59.99** | §1, §10.4 Pricing |
| 2 | Mac channel | **Mac App Store only** (no direct download) | §9.1, §8 Phase 1 |
| 3 | Languages | **English at launch**, more languages in later months | §5, Phase 3 |
| 4 | Mobile full-screen vs. camera | Asked how recording works if the prompter is full-screen → mobile has **Record** (camera + floating overlay, R2) and **Read** (text only) | §7.2, §10.2 |
| 5 | Company entity / bundle ID | Keep **`com.echoprompt.app`**. The company is now **deferred** (see R3). | §9.2 |
| 6 | POC migration | **Yes** | §8 Phase 1, §9.1 |
| 7 | After 5 free scripts | **Block starting the prompter; still allow reading and exporting scripts** | §10.4 |
| 8 | Offline subscribers | **Maximum 30 days offline, then the paywall** | §10.4 |
| 9 | Cross-device Pro | Delegated → **one purchase unlocks all devices** through an optional account | §10.4 |
| 10 | Analytics consent | **Region-based** | §10.1 |
| 11 | Desktop video | **Mobile/tablet in Stage 2; desktop webcam in Phase 3** | §10.2, Phase 3 |
| 12 | Free tier and commercial use | **Allowed** | §10.3 |
| — | Linux | **Dropped** | Scope, §3.4, §4 |
| 13 | Free-tier retakes | Delegated → **re-runs of the 5 free scripts allowed**; rewrite-fingerprint rule prevents abuse | §10.4 |
| 14 | Business entity country | **Portugal**. Applies when the company is formed in Phase 5. EU data hosting and basic GDPR consent apply from v1. | §9.2, §9.5 |
| R1 | Desktop requirement | **Floating overlay over any app, hidden from recording software, with Normal / Voice / Audio** on macOS + Windows | Top of plan, §4, §7.1 |
| R2 | Mobile requirement | **In-app front/back camera with a floating overlay, Normal / Voice / Audio while recording, portrait + landscape** on iOS, iPadOS, Android | Top of plan, §4, §7.2, §10.2 |
| R3 | Company / legal timing | **Build and monetise first.** Launch as an individual; company, lawyer, and trademark move to **optional Phase 5** | §1, §8 Phase 5, §9.2, §9.4, §9.5, §10.3 |

Every decision marked "delegated" can be changed later. Prices and the free-tier rules are remote config or store-console settings, so they don't need an app release.

**No open questions remain.**

---

## 13. Next step

After you approve this plan, implementation starts directly with **Phase 1: Build everything**. No spikes, no gates — straight to building across all platforms.

**Before Phase 1 starts, handle these non-code tasks:**
1. Free name check for "EchoPrompt" (TMview, USPTO search).
2. Create the **individual** developer accounts: Apple ($99/yr), Google Play ($25), and Microsoft Store (free). Join the Apple Small Business Program.
3. Reserve `com.echoprompt.app` in the Apple Developer portal and Play Console, and reserve the app name in the Microsoft Store.
4. Make the GitHub repo **private** before Phase 1 ships, so no one can build the app without the paywall.

**During Phase 2 (testing & refinement):**
5. Line up **12 testers** for Google Play's 14-day closed test.
6. Open self-employed activity at Finanças before the first Phase 4 payout.

**Company, lawyer, and trademark filing wait for Phase 5 (§9.5)**, once revenue justifies it.
