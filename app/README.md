# EchoPrompt (Flutter)

Cross-platform EchoPrompt: macOS, Windows, iOS, iPadOS, Android. See `../plan/cross-platform-plan.md`.

```sh
./tools/fetch_models.sh        # one-time: English speech models (not in git)
flutter pub get
flutter test
flutter run -d macos           # or windows / an iOS or Android device
```

Running on macOS, step by step, with a manual test checklist: `docs/RUN_MACOS.md`.

Native plugins live in `../packages/`: `echoprompt_window` (desktop overlay) and `echoprompt_camera` (mobile camera).
Set `--dart-define=SENTRY_DSN=...` to enable opt-in crash reporting.
