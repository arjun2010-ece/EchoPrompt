import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:echoprompt_window/echoprompt_window.dart';

import 'core/settings/prompt_settings.dart';
import 'features/prompter/desktop_prompter_screen.dart';
import 'features/studio/desktop_studio_screen.dart';
import 'features/studio/studio_screen.dart';
import 'services/platform.dart';
import 'services/providers.dart';
import 'ui/mobile_theme.dart';
import 'services/storage/migration.dart';
import 'services/storage/script_library.dart';

const crashReportingKey = 'EchoPrompt.crashReporting.v1';
const _sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final library = ScriptLibrary(await scriptsDirectory(), prefs);

  final migrated = await migrateFromPoc(
    prefs: prefs,
    library: library,
    current: const PromptSettings(),
    legacyDefaults: isDesktop ? await EchoPromptWindow.legacyDefaults() : const {},
  );
  if (migrated != null && prefs.getString(settingsKey) == null) {
    await prefs.setString(settingsKey, jsonEncodeSettings(migrated));
  }

  Future<void> run() async => runApp(ProviderScope(
    overrides: [prefsProvider.overrideWithValue(prefs), libraryProvider.overrideWithValue(library)],
    child: const EchoPromptApp(),
  ));

  // Crash reporting is opt-in; no script content is ever attached.
  if ((prefs.getBool(crashReportingKey) ?? false) && _sentryDsn.isNotEmpty) {
    await SentryFlutter.init((o) {
      o.dsn = _sentryDsn;
      o.sendDefaultPii = false;
      o.attachScreenshot = false;
      o.maxBreadcrumbs = 0;
    }, appRunner: run);
  } else {
    await run();
  }
}

/// Desktop Material buttons default to the arrow cursor; show a hand on enabled ones.
ThemeData _theme(Brightness brightness) {
  final cursor = WidgetStateProperty.resolveWith<MouseCursor>(
    (states) => states.contains(WidgetState.disabled) ? SystemMouseCursors.basic : SystemMouseCursors.click,
  );
  final style = ButtonStyle(mouseCursor: cursor);
  return ThemeData(
    colorSchemeSeed: Colors.orange,
    brightness: brightness,
    filledButtonTheme: FilledButtonThemeData(style: style),
    elevatedButtonTheme: ElevatedButtonThemeData(style: style),
    outlinedButtonTheme: OutlinedButtonThemeData(style: style),
    textButtonTheme: TextButtonThemeData(style: style),
    iconButtonTheme: IconButtonThemeData(style: style),
    segmentedButtonTheme: SegmentedButtonThemeData(style: style),
  );
}

class EchoPromptApp extends ConsumerWidget {
  const EchoPromptApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(settingsProvider.select((s) => s.studioAppearance));
    final presenting = isDesktop && ref.watch(studioProvider.select((s) => s.presenting));
    return MaterialApp(
      title: 'EchoPrompt',
      debugShowCheckedModeBanner: false,
      theme: isDesktop ? _theme(Brightness.light) : mobileTheme(Brightness.light),
      darkTheme: isDesktop ? _theme(Brightness.dark) : mobileTheme(Brightness.dark),
      themeMode: switch (appearance) {
        StudioAppearance.system => ThemeMode.system,
        StudioAppearance.light => ThemeMode.light,
        StudioAppearance.dark => ThemeMode.dark,
      },
      home: !isDesktop
          ? const StudioScreen()
          : presenting
              ? const DesktopPrompterScreen()
              : const DesktopStudioScreen(),
    );
  }
}
