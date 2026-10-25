# EchoPrompter (Flutter)

Cross-platform EchoPrompter: macOS, Windows, iOS, iPadOS, Android. See `../plan/cross-platform-plan.md`.

```sh
flutter pub get
flutter test
flutter run -d macos           # or windows / an iOS or Android device
```

Running on macOS, step by step, with a manual test checklist: `docs/RUN_MACOS.md`.

Native plugins live in `../packages/`: `echoprompter_window` (desktop overlay) and `echoprompter_camera` (mobile camera).
Set `--dart-define=SENTRY_DSN=...` to enable opt-in crash reporting.
