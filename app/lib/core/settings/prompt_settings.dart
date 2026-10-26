import 'dart:ui' show Size;

enum StudioAppearance { system, light, dark }

enum PromptControlMode { normal, voice, recordedAudio }

enum PromptPlacement { notch, corner, floating }

/// Space either side of the text. Medium is what the prompter always used.
enum PromptMargins {
  narrow(0.5),
  medium(1),
  wide(1.8);

  const PromptMargins(this.scale);

  /// Multiplies the layout's side padding.
  final double scale;
}

/// Bundled fonts for the prompter text; [family] is null for the system font.
enum PromptFont {
  system(null),
  serif('PTSerif'),
  rounded('VarelaRound'),
  hyperlegible('AtkinsonHyperlegible');

  const PromptFont(this.family);
  final String? family;
}

enum PromptCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Valid ranges, shared by every slider and by loading saved settings, so a
/// value saved by an older build can never push the prompter out of range.
class PromptLimits {
  const PromptLimits._();
  static const fontSize = (min: 16.0, max: 110.0);
  static const lineSpacing = (min: 0.9, max: 2.0);
  static const speed = (min: 5.0, max: 100.0);
  static const opacity = (min: 0.25, max: 1.0);
}

double _clamp(num v, ({double min, double max}) r) => v.clamp(r.min, r.max).toDouble();

/// Out-of-range saved values came from an older, wrongly-ranged slider rather
/// than from the user's intent, so they fall back to the default.
double _inRangeOr(num? v, ({double min, double max}) r, double fallback) =>
    v == null || v < r.min || v > r.max ? fallback : v.toDouble();

class PromptSettings {
  const PromptSettings({
    this.fontSize = 25,
    this.lineSpacing = 1.0,
    this.speed = 24,
    this.opacity = 0.92,
    this.studioAppearance = StudioAppearance.dark,
    this.mirror = false,
    this.rotated = false,
    this.mode = PromptControlMode.normal,
    this.placement = PromptPlacement.floating,
    this.corner = PromptCorner.topRight,
    this.hideFromCapture = true,
    this.readingGuide = true,
    this.showProgress = true,
    this.showSections = true,
    this.margins = PromptMargins.medium,
    this.font = PromptFont.system,
    this.notchSize = const Size(560, 150),
    this.cornerSize = const Size(420, 240),
  });

  final double fontSize;
  /// Line height as a multiple of the font size (0.9–2.0).
  final double lineSpacing;
  /// Normal-mode scroll speed in points/second (the Swift app's base is 24).
  final double speed;
  final double opacity;
  final StudioAppearance studioAppearance;
  final bool mirror;

  /// Rotate the text 180° (mobile glass rigs only; desktop OSes rotate displays).
  final bool rotated;
  final PromptControlMode mode;
  final PromptPlacement placement;
  final PromptCorner corner;
  final bool hideFromCapture;

  /// Desktop: small `› ‹` marks at the line the prompter keeps you reading on.
  final bool readingGuide;

  /// Desktop: the progress, elapsed and remaining line under the controls.
  final bool showProgress;

  /// Desktop: section names between parts of the script (`[Intro]` lines).
  final bool showSections;
  final PromptMargins margins;
  final PromptFont font;

  /// Whether every option under "Text" is at its default, so Reset has nothing to do.
  bool get isTextDefault {
    const d = PromptSettings();
    return fontSize == d.fontSize &&
        lineSpacing == d.lineSpacing &&
        opacity == d.opacity &&
        readingGuide == d.readingGuide &&
        showProgress == d.showProgress &&
        showSections == d.showSections &&
        margins == d.margins &&
        font == d.font;
  }

  /// Notch body size; height excludes the hardware notch inset.
  final Size notchSize;
  final Size cornerSize;

  PromptSettings copyWith({
    double? fontSize,
    double? lineSpacing,
    double? speed,
    double? opacity,
    StudioAppearance? studioAppearance,
    bool? mirror,
    bool? rotated,
    PromptControlMode? mode,
    PromptPlacement? placement,
    PromptCorner? corner,
    bool? hideFromCapture,
    bool? readingGuide,
    bool? showProgress,
    bool? showSections,
    PromptMargins? margins,
    PromptFont? font,
    Size? notchSize,
    Size? cornerSize,
  }) => PromptSettings(
    fontSize: _clamp(fontSize ?? this.fontSize, PromptLimits.fontSize),
    lineSpacing: _clamp(lineSpacing ?? this.lineSpacing, PromptLimits.lineSpacing),
    speed: _clamp(speed ?? this.speed, PromptLimits.speed),
    opacity: _clamp(opacity ?? this.opacity, PromptLimits.opacity),
    studioAppearance: studioAppearance ?? this.studioAppearance,
    mirror: mirror ?? this.mirror,
    rotated: rotated ?? this.rotated,
    mode: mode ?? this.mode,
    placement: placement ?? this.placement,
    corner: corner ?? this.corner,
    hideFromCapture: hideFromCapture ?? this.hideFromCapture,
    readingGuide: readingGuide ?? this.readingGuide,
    showProgress: showProgress ?? this.showProgress,
    showSections: showSections ?? this.showSections,
    margins: margins ?? this.margins,
    font: font ?? this.font,
    notchSize: notchSize ?? this.notchSize,
    cornerSize: cornerSize ?? this.cornerSize,
  );

  Map<String, Object> toJson() => {
    'fontSize': fontSize,
    'lineSpacing': lineSpacing,
    'speed': speed,
    'opacity': opacity,
    'studioAppearance': studioAppearance.name,
    'mirror': mirror,
    'rotated': rotated,
    'mode': mode.name,
    'placement': placement.name,
    'corner': corner.name,
    'hideFromCapture': hideFromCapture,
    'readingGuide': readingGuide,
    'showProgress': showProgress,
    'showSections': showSections,
    'margins': margins.name,
    'font': font.name,
    'notchW': notchSize.width,
    'notchH': notchSize.height,
    'cornerW': cornerSize.width,
    'cornerH': cornerSize.height,
  };

  factory PromptSettings.fromJson(Map<String, Object?> j) {
    T e<T extends Enum>(List<T> v, Object? n, T d) =>
        v.firstWhere((x) => x.name == n, orElse: () => d);
    const d = PromptSettings();
    return PromptSettings(
      fontSize: _clamp((j['fontSize'] as num?) ?? d.fontSize, PromptLimits.fontSize),
      lineSpacing: _inRangeOr(j['lineSpacing'] as num?, PromptLimits.lineSpacing, d.lineSpacing),
      speed: _inRangeOr(j['speed'] as num?, PromptLimits.speed, d.speed),
      opacity: _clamp((j['opacity'] as num?) ?? d.opacity, PromptLimits.opacity),
      studioAppearance: e(StudioAppearance.values, j['studioAppearance'], d.studioAppearance),
      mirror: j['mirror'] as bool? ?? d.mirror,
      rotated: j['rotated'] as bool? ?? d.rotated,
      mode: e(PromptControlMode.values, j['mode'], d.mode),
      placement: e(PromptPlacement.values, j['placement'], d.placement),
      corner: e(PromptCorner.values, j['corner'], d.corner),
      hideFromCapture: j['hideFromCapture'] as bool? ?? d.hideFromCapture,
      readingGuide: j['readingGuide'] as bool? ?? d.readingGuide,
      showProgress: j['showProgress'] as bool? ?? d.showProgress,
      showSections: j['showSections'] as bool? ?? d.showSections,
      margins: e(PromptMargins.values, j['margins'], d.margins),
      font: e(PromptFont.values, j['font'], d.font),
      notchSize: Size(
        (j['notchW'] as num?)?.toDouble() ?? d.notchSize.width,
        (j['notchH'] as num?)?.toDouble() ?? d.notchSize.height,
      ),
      cornerSize: Size(
        (j['cornerW'] as num?)?.toDouble() ?? d.cornerSize.width,
        (j['cornerH'] as num?)?.toDouble() ?? d.cornerSize.height,
      ),
    );
  }
}
