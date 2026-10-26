import 'package:flutter/material.dart';

/// The desktop palettes from the macOS design: neutral greys in the order macOS stacks them (page,
/// sidebar, inspector, toolbar, cards), a blue for actions and controls, and an amber reserved for
/// Pro. The prompter keeps its own black in both.
class DesktopPalette {
  const DesktopPalette({
    required this.brightness,
    required this.page,
    required this.sidebar,
    required this.inspector,
    required this.toolbar,
    required this.card,
    required this.tile,
    required this.well,
    required this.border,
    required this.buttonBorder,
    required this.outline,
    required this.selectedRow,
    required this.text,
    required this.textMuted,
    required this.textDisabled,
    required this.icon,
    required this.action,
    required this.accent,
    required this.link,
    required this.danger,
    required this.dangerContainer,
    required this.success,
    required this.segmentSelected,
    required this.segmentSelectedText,
    required this.switchOff,
    required this.proTint,
    required this.successTint,
  });

  final Brightness brightness;
  final Color page, sidebar, inspector, toolbar, card, tile, well, border, buttonBorder, outline;
  final Color selectedRow, text, textMuted, textDisabled, icon;

  /// Fill of the main (Start, Save) buttons; darker than [accent] so white text stays readable.
  final Color action;

  /// Sliders, switches, progress and the focus ring.
  final Color accent;

  /// Text buttons and links.
  final Color link;
  final Color danger, dangerContainer, success;
  final Color segmentSelected, segmentSelectedText, switchOff;

  /// Backgrounds for the Pro warning panel and the success badge.
  final Color proTint, successTint;

  bool get isDark => brightness == Brightness.dark;

  static const dark = DesktopPalette(
    brightness: Brightness.dark,
    page: Color(0xFF1E1E1E),
    sidebar: Color(0xFF252527),
    inspector: Color(0xFF232325),
    toolbar: Color(0xFF2A2A2C),
    card: Color(0xFF2C2C2E),
    tile: Color(0xFF3A3A3C),
    well: Color(0xFF1C1C1E),
    border: Color(0xFF38383A),
    buttonBorder: Color(0xFF4A4A4E),
    outline: Color(0xFF636366),
    selectedRow: Color(0xFF24406A),
    text: Color(0xFFEBEBF0),
    textMuted: Color(0xFFA1A1A6),
    textDisabled: Color(0xFF6E6E73),
    icon: Color(0xFFC7C7CC),
    action: Color(0xFF0B63CE),
    accent: Color(0xFF0A84FF),
    link: Color(0xFF4DA3FF),
    danger: Color(0xFFFF8A82),
    dangerContainer: Color(0xFF3A2624),
    success: Color(0xFF30D158),
    segmentSelected: Color(0xFF5A5A5E),
    segmentSelectedText: Colors.white,
    switchOff: Color(0xFF4A4A4E),
    proTint: Color(0xFF33291A),
    successTint: Color(0xFF1E3A26),
  );

  static const light = DesktopPalette(
    brightness: Brightness.light,
    page: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF3F3F5),
    inspector: Color(0xFFF7F7F9),
    toolbar: Color(0xFFECECEE),
    card: Color(0xFFFFFFFF),
    tile: Color(0xFFE5E5EA),
    well: Color(0xFFE3E3E8),
    border: Color(0xFFD8D8DC),
    buttonBorder: Color(0xFFC7C7CC),
    outline: Color(0xFFAEAEB2),
    selectedRow: Color(0xFFD4E4FB),
    text: Color(0xFF1D1D1F),
    textMuted: Color(0xFF6B6B70),
    textDisabled: Color(0xFFA8A8AD),
    icon: Color(0xFF5C5C61),
    action: Color(0xFF0B63CE),
    accent: Color(0xFF007AFF),
    link: Color(0xFF0A60D6),
    danger: Color(0xFFD70015),
    dangerContainer: Color(0xFFFDECEA),
    success: Color(0xFF1F9D43),
    segmentSelected: Colors.white,
    segmentSelectedText: Color(0xFF1D1D1F),
    switchOff: Color(0xFFC7C7CC),
    proTint: Color(0xFFFFF4DF),
    successTint: Color(0xFFDDF5E4),
  );
}

/// Amber, for Pro only. Its text and icons use a deeper shade on light surfaces.
const proAmber = Color(0xFFFFB340);

ColorScheme _scheme(DesktopPalette p) => ColorScheme(
  brightness: p.brightness,
  primary: p.accent,
  onPrimary: Colors.white,
  primaryContainer: p.selectedRow,
  onPrimaryContainer: p.text,
  secondary: proAmber,
  onSecondary: const Color(0xFF1A1A1A),
  tertiary: p.success,
  onTertiary: Colors.white,
  tertiaryContainer: p.isDark ? const Color(0xFF3A3326) : const Color(0xFFFBEBC9),
  onTertiaryContainer: p.isDark ? const Color(0xFFF5C26B) : const Color(0xFF8A5A00),
  error: p.danger,
  onError: p.isDark ? const Color(0xFF3A0B07) : Colors.white,
  errorContainer: p.dangerContainer,
  onErrorContainer: p.isDark ? const Color(0xFFFFC9C4) : const Color(0xFF8B1A12),
  surface: p.page,
  onSurface: p.text,
  onSurfaceVariant: p.textMuted,
  outline: p.outline,
  outlineVariant: p.border,
  surfaceContainerLowest: p.isDark ? const Color(0xFF161618) : const Color(0xFFFFFFFF),
  surfaceContainerLow: p.inspector,
  surfaceContainer: p.sidebar,
  surfaceContainerHigh: p.card,
  surfaceContainerHighest: p.tile,
  inverseSurface: p.text,
  onInverseSurface: p.page,
  inversePrimary: p.action,
  shadow: Colors.black,
  scrim: Colors.black,
);

ThemeData desktopDarkTheme(ButtonStyle cursor) => _desktopTheme(DesktopPalette.dark, cursor);
ThemeData desktopLightTheme(ButtonStyle cursor) => _desktopTheme(DesktopPalette.light, cursor);

/// Component themes on top of the palette's colour scheme; [cursor] is the hand-on-enabled-buttons style.
ThemeData _desktopTheme(DesktopPalette p, ButtonStyle cursor) {
  final shape = WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)));
  final panelShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: p.isDark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6)),
  );
  bool off(Set<WidgetState> s) => s.contains(WidgetState.disabled);
  return ThemeData(
    useMaterial3: true,
    colorScheme: _scheme(p),
    scaffoldBackgroundColor: p.page,
    canvasColor: p.page,
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    appBarTheme: AppBarTheme(backgroundColor: p.toolbar, surfaceTintColor: Colors.transparent, scrolledUnderElevation: 0, elevation: 0),
    drawerTheme: DrawerThemeData(backgroundColor: p.sidebar, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: p.card, surfaceTintColor: Colors.transparent, shape: panelShape),
    popupMenuTheme: PopupMenuThemeData(color: p.card, surfaceTintColor: Colors.transparent, shape: panelShape),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.isDark ? p.tile : const Color(0xFF323236),
      contentTextStyle: TextStyle(color: p.isDark ? p.text : Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    // Main buttons are the darker blue; text buttons and links the lighter one.
    filledButtonTheme: FilledButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => off(s) ? p.tile : p.action),
        foregroundColor: WidgetStateProperty.resolveWith((s) => off(s) ? p.textDisabled : Colors.white),
        shape: shape,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: cursor),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => off(s) ? p.card : p.tile),
        foregroundColor: WidgetStateProperty.resolveWith((s) => off(s) ? p.textDisabled : p.text),
        side: WidgetStatePropertyAll(BorderSide(color: p.buttonBorder)),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cursor.copyWith(foregroundColor: WidgetStateProperty.resolveWith((s) => off(s) ? p.textDisabled : p.link)),
    ),
    iconButtonTheme: IconButtonThemeData(style: cursor.copyWith(foregroundColor: WidgetStatePropertyAll(p.icon))),
    // macOS-style segmented control: a well with the selected segment raised.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: cursor.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.segmentSelected : p.well),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.segmentSelectedText : p.icon),
        side: WidgetStatePropertyAll(BorderSide(color: p.border)),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.switchOff),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: p.accent, thumbColor: p.isDark ? Colors.white : p.accent, inactiveTrackColor: p.isDark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: p.tile),
    checkboxTheme: CheckboxThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : null)),
    inputDecorationTheme: InputDecorationThemeData(hintStyle: TextStyle(color: p.isDark ? const Color(0xFF8E8E93) : const Color(0xFF86868B))),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.isDark ? p.tile : const Color(0xFF323236), borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: p.isDark ? p.text : Colors.white, fontSize: 12),
    ),
  );
}
