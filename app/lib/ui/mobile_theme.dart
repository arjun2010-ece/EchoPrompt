import 'package:flutter/material.dart';

/// Warm, quiet theme for the iPhone, iPad and Android interface. Desktop keeps
/// its own theme. The prompter itself is always white-on-black with an amber
/// reading line, so the app chrome borrows that amber as its single accent.
const _amber = Color(0xFFE8801C);

ThemeData mobileTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _amber, brightness: brightness).copyWith(
    primary: dark ? const Color(0xFFFFA24A) : const Color(0xFFB85A00),
    onPrimary: dark ? const Color(0xFF1B0F00) : Colors.white,
    surface: dark ? const Color(0xFF141311) : const Color(0xFFFAF7F2),
    surfaceContainerLow: dark ? const Color(0xFF1B1A17) : const Color(0xFFF3EFE8),
    surfaceContainer: dark ? const Color(0xFF211F1C) : const Color(0xFFEDE8DF),
    surfaceContainerHigh: dark ? const Color(0xFF2A2825) : const Color(0xFFE6E0D5),
  );
  const shape = StadiumBorder();
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 2)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape, minimumSize: const Size(48, 52), padding: const EdgeInsets.symmetric(horizontal: 24)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: shape, minimumSize: const Size(48, 52), padding: const EdgeInsets.symmetric(horizontal: 22)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape, minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
  );
}
