import 'dart:async';
import 'dart:io';

import 'package:echoprompt_camera/echoprompt_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/settings/prompt_settings.dart';
import '../../services/permissions/permissions.dart';
import '../../services/analytics/analytics_service.dart';
import '../../services/providers.dart';
import '../prompter/prompt_view.dart';
import '../prompter/prompter_controller.dart';
import '../read/reading_settings.dart';
import '../read/script_editor_sheet.dart';

/// R2: in-app camera (front/back) with the prompter overlay docked at the
/// top, in portrait and landscape. The prompter is a UI overlay only and is
/// never part of the recorded file.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});
  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> with WidgetsBindingObserver {
  CameraFacing _facing = CameraFacing.front;
  CameraPreviewInfo? _preview;
  String? _error;
  bool _recording = false;
  bool _paused = false;
  int? _countdown;
  bool _useCountdown = true;
  int _recordings = 0;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  ReferenceRoute _route = ReferenceRoute.silent;
  StreamSubscription<Map<Object?, Object?>>? _events;
  DateTime? _micStart;
  bool _opening = false;
  // Cached because `ref` can't be read in dispose().
  late final AnalyticsService _analytics;
  static const _pausedColor = Colors.amber;

  // Overlay height as a fraction of the screen, remembered per orientation.
  double _fractionFor(bool landscape) =>
      ref.read(prefsProvider).getDouble('EchoPrompt.overlay.${landscape ? 'l' : 'p'}') ?? (landscape ? 0.4 : 0.3);
  void _saveFraction(bool landscape, double v) =>
      ref.read(prefsProvider).setDouble('EchoPrompt.overlay.${landscape ? 'l' : 'p'}', v);
  final _dragFractions = <bool, double>{};
  static const _barHeight = 56.0;
  static const _recordButtonSize = 45.0;
  static const _fadeIn = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _analytics = ref.read(analyticsProvider);
    _analytics.log('video_mode_enter');
    _init();
  }

  /// Resolves once the push transition has finished, so camera and recognizer
  /// start-up never competes with it for the UI thread.
  Future<void> _transitionDone() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) return;
    final done = Completer<void>();
    void listener(AnimationStatus st) {
      if (st == AnimationStatus.completed && !done.isCompleted) done.complete();
    }
    animation.addStatusListener(listener);
    await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    animation.removeStatusListener(listener);
  }

  Future<void> _init() async {
    await _transitionDone();
    if (!mounted) return;
    final a = ref.read(analyticsProvider);
    final cam = await requestPermission(Permission.camera, 'camera', a);
    final mic = await requestPermission(Permission.microphone, 'mic', a);
    if (!mounted) return;
    if (!cam || !mic) {
      setState(() => _error = 'Camera and microphone access are needed to record.');
      return;
    }
    // Audio mode's video must contain the audio file, so it plays out loud and
    // the microphone records it; other modes pace silently or into headphones.
    _route = ref.read(settingsProvider).mode == PromptControlMode.recordedAudio
        ? ReferenceRoute.speaker
        : await EchoPromptCamera.headphonesConnected ? ReferenceRoute.headphones : ReferenceRoute.silent;
    _events = EchoPromptCamera.events.listen((e) {
      final type = e['type'];
      if (type == 'interrupted' || type == 'storage_full') _onStopped(null, '$type');
    });
    await _startPreview();
    // Let the preview paint before the prompter does heavy start-up work
    // (e.g. transcribing the audio file in Audio mode) on the same thread.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _beginPrompter();
  }

  Future<void> _startPreview() async {
    if (_opening) return;
    _opening = true;
    try {
      final p = await EchoPromptCamera.startPreview(_facing);
      if (!mounted) {
        // Left the screen while the camera was opening: release it again.
        EchoPromptCamera.stopPreview();
        return;
      }
      setState(() => _preview = p);
    } on PlatformException catch (e) {
      if (e.code != 'cancelled' && mounted) setState(() => _error = '$e');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _opening = false;
    }
  }

  void _beginPrompter() {
    final studio = ref.read(studioProvider);
    final s = ref.read(settingsProvider);
    ref.read(prompterProvider.notifier).begin(
      sessionId: studio.sessionId,
      script: studio.script,
      mode: s.mode,
      audioPath: ref.read(audioPathProvider),
      audible: _route != ReferenceRoute.silent,
      // One mic stream feeds the video file and the speech engine.
      externalSamples: EchoPromptCamera.audioSamples,
    );
  }

  Future<void> _edit() async {
    if (await showScriptEditor(context, ref)) _beginPrompter();
  }

  Future<void> _flip() async {
    if (_recording) return;
    _facing = _facing == CameraFacing.front ? CameraFacing.back : CameraFacing.front;
    final p = await EchoPromptCamera.switchCamera(_facing);
    if (!mounted) {
      EchoPromptCamera.stopPreview();
      return;
    }
    setState(() => _preview = p);
  }

  /// Releases the camera while the app is in the background and reopens it on
  /// return, so the camera is never held (or the privacy indicator lit) off screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_preview == null) return;
      EchoPromptCamera.stopPreview();
      setState(() => _preview = null);
    } else if (state == AppLifecycleState.resumed && _preview == null && _error == null && !_opening) {
      _startPreview();
    }
  }

  void _startTimer() =>
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _elapsed += const Duration(seconds: 1)));

  Future<void> _togglePause() async {
    HapticFeedback.mediumImpact();
    final prompter = ref.read(prompterProvider.notifier);
    if (_paused) {
      await EchoPromptCamera.resumeRecording();
      _startTimer();
      setState(() => _paused = false);
      await prompter.play();
    } else {
      _timer?.cancel();
      await EchoPromptCamera.pauseRecording();
      setState(() => _paused = true);
      await prompter.pause();
    }
  }

  void _home() => Navigator.of(context).popUntil((r) => r.isFirst);

  /// Close while recording: save the take, or discard it and go back to the
  /// scripts. [home] also leaves for the scripts list after saving.
  Future<void> _confirmClose({bool home = false}) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish this recording?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'exit'), child: const Text('Exit recording')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (choice == null || !_recording || !mounted) return;
    await ref.read(prompterProvider.notifier).pause();
    final r = await EchoPromptCamera.stopRecording();
    if (choice == 'save') {
      await _onStopped(r, 'user');
      if (home && mounted) _home();
      return;
    }
    await _onStopped(null, 'discarded');
    try {
      await File(r.path).delete();
    } catch (_) {}
    if (mounted) _home();
  }

  Future<void> _toggleRecord(bool landscape) async {
    final prompter = ref.read(prompterProvider.notifier);
    final analytics = ref.read(analyticsProvider);
    if (_recording) {
      await prompter.pause();
      final r = await EchoPromptCamera.stopRecording();
      await _onStopped(r, 'user');
      return;
    }
    if (_useCountdown) {
      for (var i = 3; i >= 1; i--) {
        setState(() => _countdown = i);
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
      }
      setState(() => _countdown = null);
    }
    // Orientation is locked while recording so the file has one orientation.
    await SystemChrome.setPreferredOrientations(
      landscape ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp],
    );
    final mode = ref.read(settingsProvider).mode;
    await EchoPromptCamera.setReferenceRoute(_route);
    await EchoPromptCamera.startRecording(landscape: landscape);
    analytics.log('video_record_start', {
      'orientation': landscape ? 'landscape' : 'portrait',
      'camera': _facing.name,
      'prompter_mode': mode.name,
      'resolution': '1080p',
    });
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
    });
    _startTimer();
    if (mode == PromptControlMode.voice) _micStart = DateTime.now();
    // Playback / scrolling starts on the first recorded frame (after the
    // countdown); Audio mode's clock starts here too.
    await prompter.play();
  }

  Future<void> _onStopped(RecordingResult? r, String reason) async {
    _timer?.cancel();
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final a = ref.read(analyticsProvider);
    if (_micStart != null) {
      a.log('mic_stop', {'duration_s': DateTime.now().difference(_micStart!).inSeconds, 'reason': reason});
      _micStart = null;
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _paused = false;
    });
    if (r == null) return;
    _recordings++;
    a.log('video_record_stop', {'duration_s': r.duration.inSeconds, 'reason': r.reason});
    try {
      await EchoPromptCamera.saveToGallery(r.path);
      a.log('video_saved', {'duration_s': r.duration.inSeconds});
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(reason == 'user' ? 'Saved to your gallery' : 'Recording stopped ($reason) — saved what was recorded'),
      action: SnackBarAction(label: 'Share', onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(r.path)]))),
    ));
  }

  @override
  void dispose() {
    // First, so nothing below can keep the camera open.
    EchoPromptCamera.stopPreview();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _events?.cancel();
    _analytics.log('video_mode_exit', {'recordings_count': _recordings});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider.select((s) => s.mode), (_, mode) {
      if (_recording) return;
      if (mode == PromptControlMode.recordedAudio) _route = ReferenceRoute.speaker;
      _beginPrompter();
    });
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final fraction = _dragFractions[landscape] ?? _fractionFor(landscape);
    final p = _preview;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (p == null && _error == null) const Center(child: CircularProgressIndicator(color: Colors.white54)),
        if (p != null)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: _fadeIn,
            builder: (_, v, child) => Opacity(opacity: v, child: child),
            child: Center(
              child: AspectRatio(
                aspectRatio: p.aspectRatio,
                child: Transform.flip(
                  flipX: p.mirrored,
                  child: RotatedBox(quarterTurns: p.quarterTurns, child: Texture(textureId: p.textureId)),
                ),
              ),
            ),
          ),
        if (_error != null)
          Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center))),
        // Floating prompter overlay docked at the top, below the safe area.
        Positioned(
          left: 12,
          right: 12,
          top: media.padding.top + 12,
          height: media.size.height * fraction,
          // Appears together with the camera instead of before it.
          child: AnimatedOpacity(
            opacity: p == null ? 0 : 1,
            duration: _fadeIn,
            child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: PromptView(
                style: PromptLayoutStyle.compact,
                backgroundOpacity: ref.watch(settingsProvider.select((s) => s.opacity)) * 0.4,
                showControls: false,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => setState(() {
                  _dragFractions[landscape] = ((fraction * media.size.height + d.delta.dy) / media.size.height).clamp(0.15, 0.7);
                }),
                onVerticalDragEnd: (_) => _saveFraction(landscape, _dragFractions[landscape] ?? fraction),
                child: const SizedBox(height: 22, child: Center(child: Icon(Icons.drag_handle, color: Colors.white70, size: 18))),
              ),
            ),
            ]),
          ),
        ),
        if (_countdown != null)
          Center(child: Text('$_countdown', style: const TextStyle(color: Colors.white, fontSize: 120, fontWeight: FontWeight.bold))),
        if (_recording)
          Positioned(
            right: 12,
            bottom: media.padding.bottom + 12 + _barHeight + 12 + _recordButtonSize + 12,
            child: Chip(
              avatar: _paused
                  ? const Icon(Icons.pause, color: _pausedColor, size: 14)
                  : const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
              label: Text(_fmt(_elapsed)),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: media.padding.bottom + 12 + _barHeight + 12,
          // Equal side slots keep the record button centred.
          child: Row(children: [
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton.filledTonal(
                  tooltip: 'Flip camera',
                  icon: const Icon(Icons.cameraswitch),
                  onPressed: _recording ? null : _flip,
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Edit script',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _recording ? null : _edit,
                ),
              ]),
            ),
            Semantics(
              button: true,
              label: _recording ? 'Stop recording' : 'Start recording',
              child: GestureDetector(
                onTap: p == null || _countdown != null ? null : () => _toggleRecord(landscape),
                child: Container(
                  width: _recordButtonSize,
                  height: _recordButtonSize,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                  padding: const EdgeInsets.all(6),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(_recording ? 3 : 40),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: _recording
                    ? IconButton.filledTonal(
                        tooltip: _paused ? 'Resume recording' : 'Pause recording',
                        icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                        onPressed: _togglePause,
                      )
                    : PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, color: Colors.white),
              onSelected: (v) => setState(() {
                switch (v) {
                  case 'countdown':
                    _useCountdown = !_useCountdown;
                  case 'headphones':
                    _route = ReferenceRoute.headphones;
                  case 'silent':
                    _route = ReferenceRoute.silent;
                  case 'speaker':
                    _route = ReferenceRoute.speaker;
                }
                if (!_recording) _beginPrompter();
              }),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(value: 'countdown', checked: _useCountdown, child: const Text('3-2-1 countdown')),
                const PopupMenuDivider(),
                const PopupMenuItem(enabled: false, child: Text('Reference audio plays through')),
                CheckedPopupMenuItem(value: 'headphones', checked: _route == ReferenceRoute.headphones, child: const Text('Headphones (not in the video)')),
                CheckedPopupMenuItem(value: 'silent', checked: _route == ReferenceRoute.silent, child: const Text('Silent pacing (not in the video)')),
                CheckedPopupMenuItem(value: 'speaker', checked: _route == ReferenceRoute.speaker, child: const Text('Speaker (in the video)')),
              ],
            ),
              ),
            ),
          ]),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: media.padding.bottom + 12,
          height: _barHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_barHeight / 2),
            child: PromptControlBar(
              onSettings: () => showReadingSettings(context, follow: false),
              compact: false,
              trailing: [
                IconButton(
                  tooltip: 'Scripts',
                  icon: const Icon(Icons.home_outlined),
                  onPressed: _recording ? () => _confirmClose(home: true) : _home,
                ),
              ],
              color: Colors.black.withValues(alpha: 0.6),
              onClose: _recording ? _confirmClose : () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ]),
    );
  }
}
