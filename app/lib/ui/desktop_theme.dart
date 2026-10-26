import 'package:flutter/material.dart';

/// The desktop dark palette from the macOS design: neutral greys in the order macOS stacks them
/// (page, sidebar, inspector, toolbar, cards), a blue for actions and controls, and an amber reserved
/// for Pro. The prompter keeps its own black.
class DesktopColors {
  const DesktopColors._();
  static const page = Color(0xFF1E1E1E);
  static const sidebar = Color(0xFF252527);
  static const inspector = Color(0xFF232325);
  static const toolbar = Color(0xFF2A2A2C);
  static const card = Color(0xFF2C2C2E);
  static const tile = Color(0xFF3A3A3C);
  static const well = Color(0xFF1C1C1E);
  static const border = Color(0xFF38383A);
  static const selectedRow = Color(0xFF24406A);

  static const text = Color(0xFFEBEBF0);
  static const textMuted = Color(0xFFA1A1A6);

  /// Fill of the main (Start, Save) buttons; darker than [accent] so white text stays readable.
  static const action = Color(0xFF0B63CE);

  /// Sliders, switches, progress and the focus ring.
  static const accent = Color(0xFF0A84FF);

  /// Text buttons and links.
  static const link = Color(0xFF4DA3FF);
  static const pro = Color(0xFFFFB340);
  static const success = Color(0xFF30D158);
  static const danger = Color(0xFFFF8A82);
}

ColorScheme desktopDarkScheme() => const ColorScheme(
  brightness: Brightness.dark,
  primary: DesktopColors.accent,
  onPrimary: Colors.white,
  primaryContainer: DesktopColors.selectedRow,
  onPrimaryContainer: Colors.white,
  secondary: DesktopColors.pro,
  onSecondary: Color(0xFF1A1A1A),
  tertiary: DesktopColors.success,
  onTertiary: Color(0xFF0B2A14),
  tertiaryContainer: Color(0xFF3A3326),
  onTertiaryContainer: Color(0xFFF5C26B),
  error: DesktopColors.danger,
  onError: Color(0xFF3A0B07),
  errorContainer: Color(0xFF3A2624),
  onErrorContainer: Color(0xFFFFC9C4),
  surface: DesktopColors.page,
  onSurface: DesktopColors.text,
  onSurfaceVariant: DesktopColors.textMuted,
  outline: Color(0xFF636366),
  outlineVariant: DesktopColors.border,
  surfaceContainerLowest: Color(0xFF161618),
  surfaceContainerLow: DesktopColors.inspector,
  surfaceContainer: DesktopColors.sidebar,
  surfaceContainerHigh: DesktopColors.card,
  surfaceContainerHighest: DesktopColors.tile,
  inverseSurface: DesktopColors.text,
  onInverseSurface: DesktopColors.page,
  inversePrimary: DesktopColors.action,
  shadow: Colors.black,
  scrim: Colors.black,
);

/// Component themes on top of [desktopDarkScheme]; [cursor] is the hand-on-enabled-buttons style.
ThemeData desktopDarkTheme(ButtonStyle cursor) {
  final scheme = desktopDarkScheme();
  final shape = WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: DesktopColors.page,
    canvasColor: DesktopColors.page,
    dividerTheme: const DividerThemeData(color: DesktopColors.border, space: 1, thickness: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: DesktopColors.toolbar,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: DesktopColors.sidebar, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(
      backgroundColor: DesktopColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF48484A))),
    ),
    popupMenuTheme: PopupMenuThemeData(color: DesktopColors.card, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Color(0xFF48484A)))),
    snackBarTheme: const SnackBarThemeData(backgroundColor: DesktopColors.tile, contentTextStyle: TextStyle(color: DesktopColors.text), behavior: SnackBarBehavior.floating),
    // Main buttons are the darker blue; text buttons and links the lighter one.
    filledButtonTheme: FilledButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DesktopColors.tile : DesktopColors.action),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? const Color(0xFF8E8E93) : Colors.white),
        shape: shape,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: cursor),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DesktopColors.card : DesktopColors.tile),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? const Color(0xFF6E6E73) : DesktopColors.text),
        side: const WidgetStatePropertyAll(BorderSide(color: Color(0xFF4A4A4E))),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cursor.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? const Color(0xFF6E6E73) : DesktopColors.link),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: cursor.copyWith(foregroundColor: const WidgetStatePropertyAll(Color(0xFFC7C7CC)))),
    // macOS-style segmented control: a dark well with the selected segment raised in grey.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Color(0xFF5A5A5E) : DesktopColors.well),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : const Color(0xFFC7C7CC)),
        side: const WidgetStatePropertyAll(BorderSide(color: DesktopColors.border)),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DesktopColors.accent : const Color(0xFF4A4A4E)),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: DesktopColors.accent, thumbColor: Colors.white, inactiveTrackColor: Color(0xFF48484A)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: DesktopColors.accent, linearTrackColor: DesktopColors.tile),
    checkboxTheme: CheckboxThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DesktopColors.accent : null)),
    inputDecorationTheme: const InputDecorationThemeData(hintStyle: TextStyle(color: Color(0xFF8E8E93))),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: DesktopColors.tile, borderRadius: BorderRadius.circular(6)), textStyle: const TextStyle(color: DesktopColors.text, fontSize: 12)),
  );
}
