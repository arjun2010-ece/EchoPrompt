# Run EchoPrompter on Windows

Use Flutter stable 3.47 or newer with Dart 3.13.5 or newer, as required by
this project's dependencies. Install Visual Studio 2022 or its Build Tools
with the C++ desktop workload, including the Windows SDK and CMake tools.
See [Flutter's Windows setup guide](https://docs.flutter.dev/platform-integration/windows/setup).

Enable **Developer Mode** in Windows Settings so Flutter can create plugin
symlinks without running your editor as administrator.

Open a new PowerShell terminal after installing Flutter or changing PATH.
From the repository root:

```powershell
cd app
flutter config --enable-windows-desktop
flutter doctor -v
flutter pub get
flutter run -d windows
```

Warnings about Android tooling do not prevent building for Windows. Resolve
any issues reported for the Windows or Visual Studio toolchains.

To build a standalone release:

```powershell
flutter build windows --release
```

The executable is `build\windows\x64\runner\Release\echoprompter.exe`.
Keep the DLLs and `data` folder alongside it when copying the app.

For a first manual check, enter a script, start the prompter in Normal mode,
and check scrolling, pause/resume, text size, mirroring, and returning to
the editor. Voice mode also needs Windows microphone and speech settings
to allow recognition.
