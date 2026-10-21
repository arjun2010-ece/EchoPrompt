import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/providers.dart';

/// Edits the current script from a prompter screen. Returns true when the text
/// changed, so the caller can restart its prompter session on the new script.
Future<bool> showScriptEditor(BuildContext context, WidgetRef ref) async {
  final before = ref.read(studioProvider).script;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (_) => const _ScriptEditorSheet(),
  );
  if (!context.mounted) return false;
  if (ref.read(studioProvider).script == before) return false;
  await ref.read(studioProvider.notifier).start();
  return true;
}

class _ScriptEditorSheet extends ConsumerStatefulWidget {
  const _ScriptEditorSheet();
  @override
  ConsumerState<_ScriptEditorSheet> createState() => _ScriptEditorSheetState();
}

class _ScriptEditorSheetState extends ConsumerState<_ScriptEditorSheet> {
  late final _controller = TextEditingController(text: ref.read(studioProvider).script);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
            child: Row(children: [
              Expanded(child: Text('Edit script', style: theme.textTheme.titleLarge)),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
            ]),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyLarge?.copyWith(fontSize: 19, height: 1.5),
              onChanged: ref.read(studioProvider.notifier).setScript,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Write or paste your script…',
                contentPadding: EdgeInsets.fromLTRB(20, 8, 20, 16),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
