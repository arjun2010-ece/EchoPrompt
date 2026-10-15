# EchoPrompt

A native SwiftUI macOS teleprompter. Paste a script, set text size and scroll speed, then open the always-on-top prompt window.

## Run

Requires macOS 13+ and Xcode's command-line tools.

```sh
swift run
```

`swift run` is for development only. It launches a debug executable, which macOS displays as `exec` in the Dock. For normal Dock behavior, build and launch the single-instance EchoPrompt app bundle:

```sh
./build-app.sh
open .build/EchoPrompt.app
```

For a screen-recorded tutorial, configure your recording software to capture the target app/window (or only the target display), while leaving the EchoPrompt window outside the captured source. The app intentionally does not try to hide from arbitrary screen-recording software.
