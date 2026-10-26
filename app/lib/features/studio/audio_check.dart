import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/providers.dart';
import '../prompter/prompter_controller.dart';

/// Whether the chosen recording can be used. Audio mode follows the file live through the
/// microphone, so there is nothing to sync beforehand; the file only has to exist and load.
enum AudioReadiness { none, ready, unreadable }

class AudioCheck {
  const AudioCheck(this.readiness, [this.seconds]);
  final AudioReadiness readiness;

  /// Length of the recording, when it could be read.
  final double? seconds;
}

/// Re-runs whenever another recording is chosen. Loading is shown as `isLoading`, and Start stays
/// off until it finishes, so the prompter never opens in Audio mode without a ready recording.
final audioCheckProvider = FutureProvider.autoDispose<AudioCheck>((ref) async {
  final path = ref.watch(audioPathProvider);
  if (path == null) return const AudioCheck(AudioReadiness.none);
  if (!File(path).existsSync()) return const AudioCheck(AudioReadiness.unreadable);
  final clock = ref.read(referenceClockFactoryProvider)(audible: false);
  try {
    final seconds = await clock.load(path);
    return seconds > 0 ? AudioCheck(AudioReadiness.ready, seconds) : const AudioCheck(AudioReadiness.unreadable);
  } catch (_) {
    return const AudioCheck(AudioReadiness.unreadable);
  } finally {
    await clock.dispose();
  }
});

/// Why Start is unavailable in Audio mode, or null when it is available.
String? audioStartBlocker(AsyncValue<AudioCheck> check) => check.when(
  loading: () => 'Start is available once the recording is checked.',
  error: (_, _) => 'Choose another recording to start.',
  data: (c) => switch (c.readiness) {
    AudioReadiness.ready => null,
    AudioReadiness.none => 'Choose a recording to start.',
    AudioReadiness.unreadable => 'Choose another recording to start.',
  },
);

String formatSeconds(double s) {
  final t = s.round();
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}
