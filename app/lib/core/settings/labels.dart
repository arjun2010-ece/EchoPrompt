import 'prompt_settings.dart';

/// User-facing names, so the UI never shows raw enum names.
extension StudioAppearanceLabel on StudioAppearance {
  String get label => switch (this) {
    StudioAppearance.system => 'System',
    StudioAppearance.light => 'Light',
    StudioAppearance.dark => 'Dark',
  };
}

extension PromptControlModeLabel on PromptControlMode {
  String get label => switch (this) {
    PromptControlMode.normal => 'Normal',
    PromptControlMode.voice => 'Voice',
    PromptControlMode.recordedAudio => 'Audio',
  };

  /// One line under the mode picker.
  String get explanation => switch (this) {
    PromptControlMode.normal => 'Scrolls smoothly at a steady pace. Never uses the microphone.',
    PromptControlMode.voice => 'Follows your voice, word by word. Listens only while the prompter is open.',
    PromptControlMode.recordedAudio => 'Follows a recording you choose, word by word.',
  };

  /// Upper-case name in the prompter header.
  String get headerName => switch (this) {
    PromptControlMode.normal => 'NORMAL SCROLLING',
    PromptControlMode.voice => 'VOICE CONTROL',
    PromptControlMode.recordedAudio => 'RECORDED AUDIO',
  };
}

extension PromptCornerLabel on PromptCorner {
  String get label => switch (this) {
    PromptCorner.topLeft => 'Top left',
    PromptCorner.topRight => 'Top right',
    PromptCorner.bottomLeft => 'Bottom left',
    PromptCorner.bottomRight => 'Bottom right',
  };
}

extension PromptPlacementLabel on PromptPlacement {
  /// [hasNotch] is true on a Mac whose display has a camera notch; everywhere
  /// else the top-centre position is called "Top center".
  String label({required bool hasNotch}) => switch (this) {
    PromptPlacement.notch => hasNotch ? 'Notch' : 'Top center',
    PromptPlacement.corner => 'Corner',
    PromptPlacement.floating => 'Floating',
  };

  String description({required bool hasNotch, required bool mac}) => switch (this) {
    PromptPlacement.notch => hasNotch
        ? 'Sits right under the camera notch, so you keep eye contact.'
        : mac
            ? 'Docks at the top center of the screen, near your camera.'
            : 'Docks at the top center, under your webcam.',
    PromptPlacement.corner => 'Snaps to a screen corner. Drag it to another corner to move it.',
    PromptPlacement.floating => 'Move and resize it anywhere. The position is remembered.',
  };
}
