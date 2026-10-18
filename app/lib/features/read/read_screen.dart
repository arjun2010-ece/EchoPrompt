import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/providers.dart';
import '../prompter/prompt_view.dart';
import '../prompter/prompter_controller.dart';

/// Mobile "Read" mode: full-screen prompter without the camera (glass rigs,
/// tablets on stands). Portrait or landscape; rotate/mirror live in settings.
class ReadScreen extends ConsumerStatefulWidget {
  const ReadScreen({super.key});
  @override
  ConsumerState<ReadScreen> createState() => _ReadScreenState();
}

class _ReadScreenState extends ConsumerState<ReadScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final studio = ref.read(studioProvider);
    ref.read(prompterProvider.notifier).begin(
      sessionId: studio.sessionId,
      script: studio.script,
      mode: ref.read(settingsProvider).mode,
      audioPath: ref.read(audioPathProvider),
    );
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider.select((s) => s.mode), (_, mode) {
      final studio = ref.read(studioProvider);
      ref.read(prompterProvider.notifier).begin(
        sessionId: studio.sessionId,
        script: studio.script,
        mode: mode,
        audioPath: ref.read(audioPathProvider),
      );
    });
    final set = ref.read(settingsProvider.notifier).update;
    final s = ref.watch(settingsProvider);
    return Scaffold(
      body: SafeArea(
        child: PromptView(
                    backgroundOpacity: 1,
          onClose: () {
            ref.read(prompterProvider.notifier).pause();
            Navigator.of(context).pop();
          },
          trailing: [
            IconButton(
              tooltip: 'Mirror',
              icon: Icon(Icons.flip, color: s.mirror ? Colors.orange : null),
              onPressed: () => set((v) => v.copyWith(mirror: !v.mirror)),
            ),
            IconButton(
              tooltip: 'Rotate 180°',
              icon: Icon(Icons.screen_rotation, color: s.rotated ? Colors.orange : null),
              onPressed: () => set((v) => v.copyWith(rotated: !v.rotated)),
            ),
          ],
        ),
      ),
    );
  }
}
