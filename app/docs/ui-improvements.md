# UI improvements: review and refined requirements

Status: proposal, reviewed 2026-10-25. Nothing here is built yet.
Scope: the Flutter app in `app/` (macOS, Windows, iOS, Android).

Guiding rule for every item: **the prompter screen stays quiet.** It is read mid-take, often on glass or in a small notch window. New controls go in panels that already exist (the "Aa" popover on desktop, Reading settings on mobile, Preferences) rather than as new buttons on the prompter.

---

## 1. Summary

Effort: **S** ≈ under a day · **M** ≈ 1–3 days · **L** ≈ about a week · **XL** = more than a week or blocked on other work.

| Priority | # | Feature | From | Effort | Platforms |
|---|---|---|---|---|---|
| Essential | E1 | Help & feedback section | extra | S | all |
| Essential | E2 | Reset text settings to defaults | 8 | S | all |
| Essential | E3 | Audio mode: Start only with a ready recording | review | S | all |
| Essential | E4 | Script title field (max 24 characters), and title + preview in the script list | 1 | M | all |
| Essential | E5 | EchoPrompter Pro: upgrade card in Script Studio, Settings tab, paywall (3 plans) | 2 | M for the screens; purchases connect in Phase 3 | all |
| Useful | U1 | Reading guide markers at the reading line | 11 | S | all |
| Useful | U2 | Side margins | extra | S–M | all |
| Useful | U3 | Font family (short curated list) | 5 | M | all |
| Useful | U4 | Progress and time row | 12 | M | all |
| Useful | U5 | Sections in the script | 9 + "Section progress tracking" | L | all |
| Useful | U6 | Notes: a place to keep reference notes, checklists and talking points | 6 | L | macOS, Windows only |
| Optional | O1 | Clear button in the mobile editor | extra | S | iOS, Android |
| Optional | O2 | Spoken commands | extra | L | all (Voice mode only) |
| Optional | O3 | Text styling (bold, italic, highlight) | 3 | XL | all |

Already built (no new work): **window opacity** (item 5). See §2.

Dropped or reduced (reasons in §3): enforcing character limits with AI, the `[Scene end]` tag, a separate EST. READ field, a settings icon in the progress row, voice "pause/continue", underline and free text colours.

---

## 2. Already in the app

These are worth knowing before building anything, so nothing is duplicated.

- **Window opacity (item 5): already exists.** Desktop has a *Background opacity* slider (25–100%) in the prompter's "Aa" popover and in Script Studio (`PromptTextControls`). Mobile shows *Overlay opacity* in Studio's settings. Only the background fades; the text stays fully readable. Making the text itself transparent is not recommended, because it only makes the script harder to read.
- **Settings can't go out of range.** `PromptLimits` clamps text size (16–110), line spacing, speed and opacity, both in the sliders and when loading saved values. Item 8 is about getting back to a comfortable default, not about values breaking (see E2).
- **Restart** is already a button and a global shortcut (⌃⌥R / Ctrl+Alt+R). This matters for spoken commands (O2).
- **Following backwards in Voice mode** already works: if you re-read a passage, the highlight moves back. This covers most of the need for a spoken "go back" (O2).
- **"Keep 20, never delete"** is already how scripts work: the list shows the 20 most recent, older `.txt` files stay in the *EchoPrompter Scripts* folder, and Import opens them. Notes (U6) should reuse the same rule.
- **Mobile already has a progress line** along the bottom of the Read screen. Desktop has none.
- **Script Studio already shows** word count and reading time (`~3 min`) for the open script.

---

## 3. Redundant or overly complex parts of the proposal

| Proposal | Issue | Recommendation |
|---|---|---|
| "Use AI tools" to enforce title/description character limits | Limits are deterministic: an input length cap plus one-line truncation with "…" does it exactly. AI would add cost, latency and a privacy question for an app that promises on-device processing. | Use `maxLength` on the title field and `maxLines: 1` + ellipsis in the list. |
| Description limited to 69 characters | Measured, one list line holds only about 28–40 characters, so 69 would take two or three lines. A character count also doesn't control visual width: "WWWW" is far wider than "iiii". | Show the start of the script as a one-line preview and let the layout truncate it. No character rule. |
| Title max 18, or 30, characters | Measured: 18 cuts common titles ("Quarterly sales review" is 22). 30 would be cut off in every narrow list. | Cap at **24** on desktop and mobile, with two small list layout changes (see E4). |
| `[Scene end]` closing tag | Extra typing and new error cases (missing end, nested scenes). A section naturally ends where the next one starts. | Only an opening marker: `[Intro]`. |
| EST. READ **and** ELAPSED **and** REMAINING | Before you start, remaining = estimated read; after you start, estimated read = elapsed + remaining. Three numbers say what two say. | Show **elapsed** and **remaining**; before Start, remaining *is* the estimate. |
| A settings icon in the progress row | The same screen already has the "Aa" button (desktop) and the Reading settings button (mobile). Two buttons for one panel. | No new icon. |
| Update progress every 5–10 s "to save memory" | Updating a short text line doesn't use meaningful memory or CPU. A clock that jumps 0:00 → 0:10 looks broken. The real cost to avoid is rebuilding the whole script text, which is solved by keeping the row in its own small widget. | Update a value only when its displayed text changes (whole %, whole second). |
| Words left **and** progress % | Same information twice in one row. | **Decided:** percentage only. Word counts stay in Studio. |
| Voice "pause" and "continue" | In Voice mode the prompter already stops when you stop talking. "Pause" would also need the microphone to keep listening for "continue". Normal mode never uses the microphone, so it can't hear commands. | Drop both (see O2). |
| Underline and free text colour in the editor | The prompter already uses an orange underline for the current word and a dimmed colour for words already read. User colours would fight those, and dark colours disappear on the black prompter and on glass rigs. | If styling is built, only bold, italic and one highlight colour (see O3). |
| Yellow scene divider | Too close to the orange used for the current word, so it reads as tracking. | A neutral or different accent colour (see U5). |
| Reset as a separate icon on the prompter | One more button on the busiest screen, and easy to hit by accident mid-take. | A "Reset" link inside the "Aa" popover and Reading settings (see E2). |
| Clear button on desktop | Duplicates New script (⌘N / Ctrl+N) and Select all + Delete. | Mobile only (see O1). |
| Notes with separate title, description and list editors | Three inputs per note, and a second copy of the whole script library. | One editor (title + text, with simple checklist lines) and the existing list, storage and import (see U6). |

---

## 4. Essential

Ordered from easiest to hardest.

### E1. Help & feedback — S

Easiest: one settings section with a link and a copy button. No state, no prompter changes.

- New last section **Help & feedback** in desktop Preferences and in mobile Studio settings (`ReadingSettings(app: true)`). Not on the prompter.
- Support address: **arjun@echoprompter.app**.
- **Email us** opens the mail app to that address, with subject "EchoPrompter feedback" and a pre-filled footer: app version, OS and version, platform. Never the script text.
- The address is also shown as text with a **Copy** button, because many Windows users have no mail app configured.
- Optional second row: **Website & FAQ** link.
- Keep the address in one constant so the website and the app can't drift apart.
- Note: opening a `mailto:` link needs `url_launcher`, which is not a dependency yet.

### E2. Reset text settings to defaults — S

Easy: the defaults already live in `const PromptSettings()`, so a reset is one `copyWith`. The prompter rebuilds from `settingsProvider`, so nothing stays stale.

- A **Reset** text button at the top of the "Aa" popover (desktop) and the *Text* section of Reading settings (mobile).
- Resets only the controls in that panel: text size, line spacing, background opacity, scroll speed, and later margins (U2) and font (U3).
- Never resets mode, position, notch/corner size, mirror, rotation, screen-sharing visibility or shortcuts. Resetting mirror mid-shoot would break a glass rig.
- Disabled when everything is already at its default.
- No confirmation dialog: the change is visible at once and easy to adjust back.

**Where text options live (decided 2026-10-26):** the Script Studio inspector shows only **Size**, plus a collapsed **More text options** row (Font, Line spacing, Margins, Background, Reading guide, Progress, Sections). The prompter's "Aa" popover shows them all, for adjusting mid-take. Both edit the same settings, and **Reset** covers all of them.

### E3. Audio mode: Start only with a ready recording — S

Easy: one extra check before starting, using the recording state the app already tracks. It also removes two prompter states ("Preparing" and "No audio file") instead of designing them.

**Decided (2026-10-26): the prompter never opens in Audio mode without a ready recording.**
- In Audio mode, **Start is disabled** until a recording is chosen **and** its words are synced. The caption under Start says what's missing:
  - No recording chosen: "Choose a recording to start."
  - Syncing: "Start is available once the words are synced." The inspector shows the sync progress.
  - File can't be read, or was moved since it was chosen: "Choose another recording to start."
- The rule covers every way of starting: the Start button, ⌘↩ / Ctrl+Enter, the Prompter menu's Start Prompter item, and the Read and Record buttons on mobile.
- The prompter therefore shows Audio mode only as playing or paused. It never shows a "Preparing" or "No audio file" state.
- Mobile Reading settings can change the mode while reading. Choosing Audio there opens the file picker first. The prompter switches to Audio only once the recording is ready, and stays in its current mode if the picker is cancelled or syncing fails.

### E4. Script title and script list — M

Medium: a model field plus migration, both editors, the list, file renaming, and two small list layout changes. No change to the prompter or tracking.

**Editor (desktop Studio, mobile Studio and the mobile editor sheet)**
- A one-line **Title** field above the body, placeholder "Title". The body field's placeholder becomes "Script".
- Max **24** characters on every platform, enforced by the field. A counter ("20/24") appears only from 20 characters. Why 24: see *Title length* below.
- Optional. If empty, the title falls back to the first line of the body, which is how titles work today. Existing scripts and quick pastes need no extra step.
- The title is never shown on the prompter, never read, and not counted in words or reading time.
- The title is part of the draft: Cancel restores it, and a title change alone enables Save.

**Storage**
- Store `title` in the history JSON (`SavedScript.toJson`). The `.txt` file keeps only the spoken text, so existing files stay valid.
- The file name comes from the title (today it comes from the first 8 words of the first line).
- When the title changes, rename the file with the same collision rule (`Name 2.txt`) and update `fileName` in the metadata.
- Import: the file name without `.txt` becomes the title, cut to 24 characters at a word boundary. Existing scripts whose first line is longer than 24 characters keep showing it with an ellipsis until a title is set. Export: file named after the title, body only.

**Script list row**
| Line | Content | Mobile and tablet | Desktop (dense list) |
|---|---|---|---|
| 1 | Title | 16 pt (`titleMedium`), 1 line, ellipsis | 14 pt (`titleSmall`), 1 line, ellipsis |
| 2 | Preview: the start of the body, line breaks collapsed to spaces | 14 pt (`bodyMedium`), 1 line, ellipsis | 12 pt (`bodySmall`), 1 line, ellipsis |
| 3 | Date · word count (as today) | 12 pt (`bodySmall`), muted | 12 pt (`bodySmall`), muted |

- Desktop keeps the existing one-step-smaller list styles. Desktop text is read closer to the screen, and macOS and Windows sidebars use 13–14 pt. A 16 pt title in the desktop sidebar would fit only about 21 characters.
- When the title came from the first line, the preview starts after that line, so the same sentence isn't shown twice.
- **Decided:** the preview is **one line**. Measured, that is about 28 characters in the narrowest lists and about 40 on a large phone, not 69. It keeps rows compact and of equal height; two lines would make each row about 20 px taller, so about one script fewer would fit on a phone screen.
- Spacing between the three lines follows the existing 2 pt gap.

**Title length: 24 characters, desktop and mobile**

One limit for every platform, because scripts move between devices by export and import, and the file name comes from the title. A title written on desktop must not be cut off on a phone.

How it was chosen:
- Measured with the list's real row layout (side padding, icon tile, buttons) and the fonts Flutter uses: SF Pro on macOS and iOS, Roboto on Android.
- The test set was 30 realistic 3–4 word titles ("Weekly team update", "Quarterly sales review", "Podcast episode 12 intro"…). Median 21 characters, 83% are 24 or fewer, 90% are 26 or fewer.
- The numbers below are characters shown whole, using the wider end of normal text (90th percentile letter width).

| List layout | Today | After the two changes below |
|---|---|---|
| Desktop sidebar (window ≥ 1040 px wide) | ~17 | ~24 |
| Desktop drawer (narrower window) | ~24 | ~24 (unchanged) |
| Tablet list pane | ~17 | ~25 |
| Phone, 360 px wide (smallest common Android) | ~18 | ~24 |
| Phone, 393 px wide (current iPhone) | ~22 | ~27 |

- 18 cuts common titles. 30 would be cut off in every narrow layout. **24 is the largest limit that shows in full on every layout**, once the two changes are made. In the test, every title of 24 characters or fewer then showed in full on every layout and both fonts.
- Change 1, **phone and tablet: remove the play button from list rows.** It does exactly what tapping the row does (opens the editor), even though its tooltip says "Start". Removing it frees 48 px and removes a redundant control.
- Change 2, **desktop: widen the sidebar from 250 to 300 px**, and move the three-column breakpoint from 1040 to 1090 px so the editor keeps its current minimum width (388 px). **Tablet: widen the list pane from 340 to 360 px.**
- The ellipsis stays as a safety net for unusually wide text (all capitals, many W and M), a larger system text size, and Segoe UI on Windows, which wasn't measured. The full title is always visible in the editor.

**Check when building:** every place that reads `SavedScript.title` (delete dialog, the "Start …" tooltip, mobile Studio, the scripts drawer) must show the new title.

### E5. EchoPrompter Pro — M for the screens (purchases connect in Phase 3)

**Decided (2026-10-25): build the Pro UI and its screens now. Don't hide them.**

**Decided (2026-10-26): buying Pro must be easy to find.** Selling Pro is the goal, so the way in can't be only a Settings tab.

The screens are moderate work: an upgrade card in the Studio sidebar, one settings tab, one sheet, one alert, and their states. The store purchase, restore and sign-in come from the Phase 3 billing work in `plan/cross-platform-plan.md` §9.3 and §10.4 (RevenueCat, Paddle, accounts). The code already routes through the `Entitlements` interface, so the screens can read the Free / Pro state from it today.

**Pro tab in Settings**
- Status: "Free · 3 of 5 scripts used", "Pro · Yearly, renews 26 Oct 2027", "Pro · Monthly, renews 12 Nov" or "Pro · Lifetime".
- **Upgrade** opens the paywall. It is hidden once the user is Pro.
- **Restore purchases**.
- **Sign in** to use Pro on all your devices (up to 5), as the plan specifies. Once signed in, it shows the account and **Sign out**.
- **Manage subscription** (Yearly and Monthly only) opens the store's subscription page.

**Upgrade card in Script Studio** (the main way in)
- A card pinned to the bottom of the sidebar, always visible to Free users, on both the Scripts and Notes lists. It is hidden for Pro users.
- **Free:** "Free plan · 3 of 5 scripts used", a progress bar, and a full-width **Upgrade to Pro** button in the Pro accent colour (amber, so it doesn't compete with the blue Start button).
- **Limit reached:** the card grows and is highlighted. "All 5 free scripts used. Upgrade to present new scripts. Your 5 scripts still work." with the same, larger **Upgrade to Pro** button.
- While selecting scripts, the selection bar takes the card's place.
- Mobile: the same card sits at the bottom of the script list.

**Start on a locked script** (one click to buy)
- When the open script would be a 6th new script, Start shows a lock and the caption "Needs Pro. You've used your 5 free scripts."
- Pressing Start (or ⌘↩) opens the paywall directly, with the reason at the top. There is no separate "limit reached" alert to click through first.
- Scripts already presented keep starting normally.
- This replaces the earlier "Free limit reached" alert.

**Paywall sheet**
- Three plans, shown in this order: **Monthly €6.99**, **Yearly €55** (shown as about €4.58 a month, saving about 34% against 12 months of Monthly) and **Lifetime €109.99**, as a one-time purchase.
- **Decided (2026-10-26):** Yearly is highlighted and selected by default.
- Prices come from the store, so they show in the user's currency.
- The buy button names the selected plan and price, for example "Subscribe for €55 a year".
- Opened from a locked Start, the subtitle gives the reason: "You've used your 5 free scripts."
- What Pro unlocks: unlimited scripts in the prompter, on all your devices.
- Restore purchases, plus Terms and Privacy links.
- States: loading prices, purchase in progress, purchase failed (with retry), restore found nothing, and success.
- The same prices, product IDs and default are in `plan/cross-platform-plan.md` (§1, §10.4 and §12).

**Subscription needs checking alert**
- Shown after 30 days offline, as the plan specifies.
- Action: **Try again**. The app re-checks automatically as soon as it's back online.
- **License key activation: not recommended as a general feature.**
  - The plan uses store billing on iOS, Mac App Store and Google Play, where Apple and Google require in-app purchase. A key field there invites review trouble and confuses buyers.
  - It only makes sense on **Windows** (Paddle) if accounts are not used there. In that case show "Enter license key" on Windows only.
  - **Deferred:** account sign-in or license key on Windows will be decided later, with the Phase 3 billing work.
- Watch out: app review rejects purchase buttons that can't complete a purchase. Connect the store purchase before the first store release that shows Upgrade.

---

## 5. Useful

Ordered from easiest to hardest.

### U1. Reading guide markers (item 11) — S

Easy: the prompter already computes the reading line (`anchorY` in `PromptSurface`). This is a small overlay there, with no change to word positions or tracking.

- Two small, static chevrons, `›` at the left edge and `‹` at the right edge, at the line the prompter keeps you reading on. Neutral, semi-transparent colour.
- They don't move with each word. The text moves to them. Moving brackets around each phrase would add motion right where the eye is.
- Most useful in **Normal** mode, which has no word highlight. In Voice and Audio mode the orange current word already marks your place; the markers still show the eyeline.
- One switch, **Reading guide**, in the "Aa" popover and Reading settings. On by default.
- Symmetric, so Mirror needs no special case. Check the 180° rotation on mobile and the narrow notch layout (16 pt side padding).

### U2. Side margins — S–M

Easy to moderate: side padding is a fixed value today (`hPad` 56 / 20 / 16, mobile max width 980). The extra work is keeping your place when lines re-wrap.

- **Margins: Narrow · Medium · Wide**, a three-option segmented control in the "Aa" popover and Reading settings. Three steps are easier than a slider and can't be pushed to an unreadable extreme.
- Medium = today's values, so existing users see no change.
- Why it matters: a narrower column keeps your eyes closer to the camera lens and suits glass rigs.
- Changing margins must keep the current word at the reading line: no jump to the top, in every mode.
- Included in Reset (E2).

### U3. Font family — M

Moderate: font files need bundling and licence notices, and line breaks change, so the layout must be redone without losing your place.

- A short list of 3–4 bundled fonts: **Default** (today's), **Serif**, **Rounded**, and **Atkinson Hyperlegible** (designed for readability, SIL OFL licence).
- No full system font list: it is long, differs between devices, and a font missing on another device changes line breaks.
- Bundled fonts look and wrap the same on every platform. Each adds roughly 100–300 KB.
- Applies to the prompter and the Studio preview. The editor keeps its normal font.
- Changing the font keeps the current word at the reading line, like U2. Included in Reset (E2).

### U4. Progress and time row (item 12) — M

Moderate: Normal, Voice and Audio mode each need their own "remaining time" calculation, and the elapsed clock must follow play and pause.

**What it shows**, one quiet line:

```
42%  ·  1:10 elapsed  ·  ~1:35 left
```

- **Progress:** whole number, rounded down, so it only says 100% at the actual end. Uses the same word position as the existing mobile progress line.
- **Elapsed:** m:ss. Counts only while scrolling or listening. Resets on Restart and when the prompter is opened again.
- **Remaining** (`~m:ss`, rounded to 5 s so it doesn't flicker):
  - Normal: remaining scroll distance ÷ scroll speed.
  - Voice: words left ÷ your measured pace over the last ~30 s, falling back to 150 words per minute.
  - Audio: audio length minus playback position.
- Before Start it shows `0%  ·  0:00  ·  ~2:30 left`, so the remaining time is the estimated read. No separate EST. READ field.
- With sections (U5) the row can start with the section name: `Demo · 42% · …`.

**Where**
- Desktop, full layout: in the footer line under the controls.
- Desktop, corner and notch: only `42%` in the hover status. There's no room for more.
- Mobile: in the dock, visible together with the other controls.

**Rules**
- **Show progress** switch in the "Aa" popover and Reading settings, on by default.
- The row is its own small widget, so a clock tick never rebuilds the script text.
- No settings icon in the row (see §3).

### U5. Sections in the script (item 9 + "Section progress tracking") — L

Hard: section lines are shown on the prompter but are never spoken. Word matching, word count, reading time, progress, tap-to-jump, recorded-audio alignment and "edit at the word you were reading" all count words, so every one of them must ignore the markers.

**Writing sections**
- A line that contains only a bracketed name starts a section:

  ```
  [Intro]
  Hi, I'm Sam and today…

  [Demo]
  Let me show you…
  ```

- A section runs until the next marker or the end of the script. **No end tag.**
- Any name works (`[Scene 1]`, `[Intro]`, `[Call to action]`), up to 40 characters. Text before the first marker is an unnamed opening section.
- Brackets inside a sentence are normal text. A line like `[text](link)` is a Markdown link, not a marker. Saving cleans Markdown; check it keeps marker lines.
- An **Insert section** button in the editor adds `[Section N]` on a new line, so nobody needs to remember the format.

**On the prompter**
- Each marker appears as a thin centred line about half the text width, with the name in small capitals: `──── DEMO ────`.
- Colour: neutral or a second accent, never yellow or orange (those mean "current word").
- No closing line. The next divider, or the end of the script, closes the section.
- Status shows `Demo · 2 of 4`, and the progress row (U4) can lead with the section name.
- **Show sections** switch, on by default. Off hides the divider lines; they are still never read.

**Implementation note.** Take markers out of the script before word processing and keep them as a separate list of (word index, name). The dividers are drawn between words. Every word index then stays the same as in the script without markers, so the tracker, audio alignment and progress code don't change. Only the display and the editor ↔ prompter position mapping need to know about markers.

**Later, not now:** a section menu to jump to a section.

### U6. Notes (item 6) — L

Hardest of the Useful items. It needs a second kind of document in the library (its own folder and history), a Scripts | Notes switch, a read view with checkboxes you can tick, and save rules that differ from scripts.

**Need.** A place to save and keep notes for reference: notes, checklists and talking points. "Protected workspace" was only a working name. In the app, call it **Notes**: short, and it needs no explanation. "Prompting notes" can describe it on the website.

**Requirements**
- **Where:** Script Studio, with a **Scripts | Notes** switch above the list. Note rows look like script rows (title, preview, date), so E4 applies.
- **A note** is a title (same 24-character limit) plus text. In the text:
  - `- [ ] item` shows as a checkbox.
  - `- item` shows as a bullet.
  - Everything else is plain text.
- That one editor covers notes, checklists and talking points, with no separate title / description / list editors.
- **Actions:** New, Import, Export and Delete work as they do for scripts, with the same shortcuts, and act on notes while Notes is selected.
- **Import** accepts `.txt` and `.md`, so notes written in other apps can be brought in.
- **Storage:** its own folder, *EchoPrompter Notes*, next to *EchoPrompter Scripts*, with its own history list. Same rule as scripts:
  - The list shows the 20 most recent.
  - Older files are never deleted automatically.
  - Import reopens them.
- **Reading a note** shows the checkboxes and bullets. Clicking a checkbox ticks it and saves `- [x]` to the file.
- **Edit** switches to the plain text editor, with the same draft, Save and Cancel as scripts.
- **No prompter controls for notes.** A note is never presented, so the inspector (mode, Start, position) is hidden while a note is open. Don't show controls that do nothing.
- **Platforms:** macOS and Windows only. **Not on mobile** (decided: not needed there), so the phone and tablet Studio get no Scripts | Notes switch.

**Watch out for**
- Saving a script removes Markdown (`cleanScript`), which would strip the `- [ ]` and `- ` markers. Notes must skip that cleaning.
- Notes are never presented, so they don't count toward the paywall's 5 free scripts.

**Later, not now:** opening a note in the prompter window, which stays on top and is hidden from screen sharing, as talking points during a call.

---

## 6. Optional

Ordered from easiest to hardest.

### O1. Clear button in the mobile editor — S

Easiest: the mobile editor already keeps a draft until Save, so clearing is safe and Cancel undoes it.

- Mobile only. On desktop, New script (⌘N / Ctrl+N) and Select all + Delete already do this.
- A **Clear** text button in the editor's top bar, shown only when the body isn't empty.
- Clears the body, not the title. Save stays disabled while the body is empty, as today.
- No dialog: a "Cleared · Undo" snackbar, and Cancel restores the saved script anyway.

### O2. Spoken commands — L

Hard: the commands must be told apart from the script text by a recogniser that already mishears about one word in five (sherpa, see `SPEECH_ENGINE_DECISION.md`). A wrongly triggered "restart" mid-take is worse than no feature.

- **Voice mode only.** It's the only mode that listens to you. Normal mode must never open the microphone, and Audio mode listens to a file.
- Keep only:
  - **Start over** = Restart. The real use is retakes.
  - **Go back** = move back to the start of the previous paragraph. Lower value, because re-reading already moves the highlight back.
- Drop:
  - **pause / continue**: Voice mode already stops when you stop talking.
  - **go to the end**: no clear use while reading.
- Avoiding false triggers:
  - Use a two-word phrase that rarely appears in scripts, e.g. "Prompter, start over".
  - Ignore a command when the words match the script text you're about to read.
- Show what was understood in the status pill ("Starting over…").

### O3. Text styling (item 3) — XL

Hardest: everything today is plain text. Styling needs a rich-text editor (a new dependency; Flutter's text field can't edit styles), a new saved format with migration, changes to import and export, a change to save-time cleaning (which removes Markdown bold and italics today), and a prompter that combines your styles with the tracking colours.

**If it is built, the minimal version:**
- **Bold**, *italic*, and **one highlight colour** (a marker for emphasis or reminders).
- Stored inside the `.txt` as `**bold**`, `*italic*` and `==highlight==`, so files stay readable in any editor and older files still open.
- On the prompter: bold weight, italic, and a soft background tint for highlights. The tracking colours (dimmed read words, orange current word) still win over the user's styling.
- A small toolbar above the editor (B, I, highlighter) acting on the selected text.

**Not recommended**
- **Underline**: the prompter uses underline for the current word.
- **Free text colour ("A") and a background colour picker ("AA")**: they clash with tracking, dark colours vanish on the black prompter and on glass, and a colour picker is a lot of UI for a reading tool. One highlight colour (or at most three presets) covers the need.

---

## 7. Suggested build order

1. **E1, E2, E3, U1, O1**: small, independent, low risk.
2. **E4** (title): touches storage, so do it before other storage changes.
3. **U2, U3**: both change line wrapping. Share the "keep the current word at the reading line" fix.
4. **U4** (progress row), then **U5** (sections), which builds on the row.
5. **U6** (notes), macOS and Windows only. It reuses the title and list work from E4.
6. **E5** Pro screens now; the store purchase connects with the Phase 3 billing work.
7. **O2, O3** only if users ask for them.

---

## 8. Decisions

No open questions remain.

Deferred:
- **Windows licensing** (account sign-in or Paddle license keys): decided later, with the Phase 3 billing work (see E5). The UI improvements come first.

Decided (2026-10-25):
- Support email: arjun@echoprompter.app.
- Items 4, 7 and 10 are not needed.
- Title limit: measured and set to 24 characters on every platform (see E4).
- "Protected workspace" was a working name for a notes area, now **Notes** (see U6).
- Notes are desktop only (macOS, Windows), not on mobile.
- The progress row shows the percentage only, no words left (see U4).
- The script list preview is one line (see E4).
- Settings has four tabs: General (Appearance, Mirror, Screen sharing, Crash reports), Shortcuts, Pro and Help. Privacy was merged into General.
- Studio inspector: only Size is always visible; other text options are behind "More text options" (see E2).
- Pro: build the UI and its screens now, not hidden until Phase 3 (see E5).

Decided (2026-10-26):
- Audio mode: the prompter opens only with a ready recording (see E3).
- Plans: Yearly €55 (the default), Monthly €6.99, Lifetime €109.99 (see E5).
- Pro is offered from the Script Studio sidebar, and Start on a locked script opens the paywall directly (see E5).
