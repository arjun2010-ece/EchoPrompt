# Android script Save / Cancel and Markdown cleaning

Android only for now (everything is gated on `isAndroid` in `lib/services/platform.dart`). iOS, iPadOS and
desktop still autosave on every keystroke and do not clean. To roll out to another platform, drop the
`isAndroid` checks listed under "Files" below.

## 1. What the reference app does (reverse engineered, `~/projects/vp-apk`)

Read from the decompile (`work/jadx-out/sources/defpackage/`); the line loop of `mu3.c` is garbled in normal JADX
output, so its control flow was confirmed from the fallback decompile (`jadx -m fallback --single-class defpackage.mu3`).

**Where it runs.** `mu3.c(text)` (a Markdown cleaner) is called by `rg3` (the script store):

| Caller | UI action | What happens |
|---|---|---|
| `wn1` case 0 | editor dialog confirm on a new script | `j0(text)`: clean, save to history, load |
| `wn1` default, `im0` case 1 | editor dialog confirm on an existing script | `x0(old, new)`: clean both; if equal after cleaning it counts as unchanged (no script-limit use); else save + load |
| `n10` case 2 | "paste from clipboard" button | clipboard text goes to `j0`, so cleaned at once |
| `jo1` | tapping a saved script | `w0` cleans again before loading (idempotent) |

Nothing cleans while typing in the text box; it happens on the dialog's confirm or the paste button.

**Rules** (per line; `\n`, `\r\n`, `\r` normalised first):

1. A line whose trimmed start is ` ``` ` or `~~~` toggles a fence and becomes an empty line. Lines inside a fence are
   **kept unchanged** (only the fences go).
2. Link-definition lines (`[x]: url`) and horizontal rules (`---`, `***`, `___`, 3 or more) become **empty lines**.
3. Otherwise, in this order: heading `^\s{0,3}#{1,6}\s+`, block quote `^\s{0,3}>\s?` (repeated for nested),
   bullet `^\s*[-+*]\s+`, **numbered list `^\s*\d{1,9}[.)]\s+`**. Each removes the marker and keeps the indent.
4. Inline: `![alt](url)`, `[text](url)` and `[text][ref]` become `text` (nested, balanced parentheses, `\` escapes);
   `<https://…>` / `<mailto:…>` keep their address; HTML tags removed; then the markers of `` `code` ``, `**bold**`,
   `__bold__`, `~~strike~~`, `*italic*`, `_italic_` are dropped and `\*`-style escapes become the plain character.
5. Each line is right-trimmed; the whole text is trimmed. Empty result: the save is ignored.

What is **kept**: numbers inside a line (`40%`, `2024`), a line starting `10 apples` (no `.`/`)`), and
`[stage directions]` in brackets (not followed by `(` or `[`).

The tracker (`ju3.d`) keeps digits (`Character.isLetterOrDigit`); it skips `[bracketed]` words, emoji and
punctuation-only tokens (`uj1.k`, `ou3`). That skipping is **not** ported yet.

## 2. What we built

* **`lib/core/script/clean_script.dart`**: `cleanScript(String)`, a faithful Dart port of the rules above.
  Dart differences handled: Java's `[^]]` is written `[^\]]`; `\p{L}` needs `unicode: true`.
* **`StudioNotifier.commitScript(text)`** (`lib/services/providers.dart`): sets `state.script` and `flush()`es at once.
* **`lib/ui/discard_changes_dialog.dart`**: `confirmDiscardChanges(context)` ("Discard changes?").
* **Studio editor** (`lib/features/studio/studio_screen.dart`, `_Editor`), inline:
  * Android typing only updates the text controller (a draft); `setScript` / the 1 s autosave are not used.
  * Cancel / Save row above the text. Both disabled unless the draft differs from the stored script; Save also
    needs a non-empty result after cleaning.
  * Save: `cleanScript` -> write into the field -> unfocus -> `commitScript`.
  * Cancel: confirm, then put the stored script back.
  * Preview / Read / Record are disabled while the draft is dirty. The stats line shows the draft.
  * `PopScope` asks before leaving with a dirty draft (narrow layout also pops after Discard).
  * Wide layout (`_SplitStudio`): a `ValueNotifier` carries the dirty flag so New script, Import and opening a
    script from the list ask first.
* **Edit sheet** (`lib/features/read/script_editor_sheet.dart`), used from the Read and Record screens: Cancel / Save
  replace Done; Save cleans, `commitScript`s and closes (`showScriptEditor` then restarts the prompter because the
  script changed); a dirty drag/back dismiss asks to discard. The sheet is modal, so Record cannot be pressed meanwhile.

Existing behaviour kept: stale-state hooks in `_Editor` (reload on `scriptRevision`, reload when the script is edited
elsewhere) now also refresh the dirty flag.

## 3. Verification done

* `cleanScript` against 12 cases (numbers, bullets, headings, quotes, inline markers, links, brackets kept, fences,
  rules and link definitions, escapes, CRLF and trim, empty result) with a throwaway script outside the repo: all pass.
* Android emulator (API 37): typed `1. Hello world` / `- bullet one 40%`, Save and Cancel enabled and Read disabled;
  after Save the text was `Hello world` / `bullet one 40%`, buttons disabled, Read enabled; back with a dirty draft showed
  the discard dialog and Discard returned to the list with the cleaned script saved; in the Edit sheet `3. Third line`
  was cleaned and the prompter restarted with it.
* `flutter analyze` clean. Existing tests were not run (project rule).

## 4. Limits and open points

* The wide split layout (landscape / tablet) guard was not exercised on a device.
* Unsaved text is lost if the app is killed mid-edit (no autosave of drafts on Android).
* Scripts saved earlier keep any list numbers until they are edited and saved again; opening a script does not
  clean it (the reference cleans again on open).
* Not done: cleaning on file import (`ScriptIO`), the paste-from-clipboard button path, skipping `[bracketed]` words /
  emoji in the tracker, and cleaning for iOS / iPadOS / desktop.
* A saved word index (`resumeWordIndex`) can point at the wrong word if a script is cleaned after progress was stored.
