import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/reading_time.dart';
import '../../core/script/saved_script.dart';
import '../../services/providers.dart';
import '../../services/storage/script_library.dart';

/// Which scripts are ticked while the list is in select mode. Null means the
/// list is not selecting. Shared by the phone, tablet and desktop layouts.
class ScriptSelection extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  void start([String? id]) => state = {?id};

  void toggle(String id) {
    final now = {...?state};
    if (!now.remove(id)) now.add(id);
    state = now;
  }

  void selectAll(Iterable<String> ids) => state = {...ids};

  void clear() => state = null;
}

final scriptSelectionProvider = NotifierProvider<ScriptSelection, Set<String>?>(ScriptSelection.new);

/// Asks, then deletes [scripts]. True if they were deleted.
Future<bool> confirmDeleteScripts(BuildContext context, WidgetRef ref, List<SavedScript> scripts) async {
  final theme = Theme.of(context);
  final shown = scripts.take(3).map((s) => s.title.trim()).toList();
  final more = scripts.length - shown.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(scripts.length == 1 ? 'Delete this script?' : 'Delete ${scripts.length} scripts?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in shown) Text('• $t', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (more > 0) Text('and $more more', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Text(
            'They are removed from your scripts folder too.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(studioProvider.notifier).deleteMany(scripts);
  return true;
}

/// "Recent scripts" with a count badge, or the select-mode title with Done.
class _Header extends ConsumerWidget {
  const _Header({required this.count});
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selecting = ref.watch(scriptSelectionProvider) != null;
    final selection = ref.read(scriptSelectionProvider.notifier);
    final label = theme.textTheme.labelMedium?.copyWith(letterSpacing: 1, color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
      child: Row(children: [
        Text(selecting ? 'SELECT SCRIPTS' : 'RECENT SCRIPTS', style: label),
        if (!selecting) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: label?.copyWith(letterSpacing: 0, color: scheme.onSurface)),
          ),
        ],
        const Spacer(),
        TextButton(
          onPressed: selecting ? selection.clear : selection.start,
          child: Text(selecting ? 'Done' : 'Select'),
        ),
      ]),
    );
  }
}

/// The saved scripts under a "Recent scripts" header, followed by the built-in
/// demo. Long-pressing a row, or Select, switches to ticking scripts to delete.
class ScriptListBody extends ConsumerWidget {
  const ScriptListBody({
    super.key,
    required this.history,
    required this.onOpen,
    required this.onOpenDemo,
    this.onRead,
    this.menuItems,
    this.onMenu,
    this.highlightCurrent = true,
    this.dense = false,
  });

  final List<SavedScript> history;
  final void Function(SavedScript) onOpen;
  final VoidCallback onOpenDemo;

  /// Shows a play button on each row when set.
  final void Function(SavedScript)? onRead;

  /// Overflow / right-click menu for a row, and what each entry does.
  final List<PopupMenuEntry<String>> Function()? menuItems;
  final void Function(SavedScript, String)? onMenu;

  /// Marks the script open in the editor.
  final bool highlightCurrent;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = ref.watch(scriptSelectionProvider);
    final selection = ref.read(scriptSelectionProvider.notifier);
    // currentId is not part of the state; these change together with it.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final demoOpen = ref.watch(studioProvider.select((s) => s.script == StudioNotifier.welcome));
    final currentId = ref.read(studioProvider.notifier).currentId;
    final selecting = picked != null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (history.isNotEmpty) _Header(count: history.length),
      for (final s in history)
        _ScriptRow(
          title: s.title.trim(),
          meta: '${friendlyDate(s.savedAt)} · ${_words(wordCount(s.body))}',
          icon: Icons.description_outlined,
          dense: dense,
          current: highlightCurrent && !selecting && s.id == currentId,
          selecting: selecting,
          ticked: picked?.contains(s.id) ?? false,
          onTap: selecting ? () => selection.toggle(s.id) : () => onOpen(s),
          onLongPress: selecting ? null : () => selection.start(s.id),
          onRead: selecting ? null : (onRead == null ? null : () => onRead!(s)),
          menuItems: selecting ? null : menuItems,
          onMenu: onMenu == null ? null : (v) => onMenu!(s, v),
        ),
      if (history.length >= ScriptLibrary.maxEntries)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Text(
            'Showing your ${ScriptLibrary.maxEntries} most recent scripts. Older ones are kept in the EchoPrompt Scripts folder; use Import to open one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      if (history.isNotEmpty) const SizedBox(height: 8),
      _ScriptRow(
        title: 'Welcome to EchoPrompt',
        meta: '${_words(wordCount(StudioNotifier.welcome))} · ${readingTimeLabel(wordCount(StudioNotifier.welcome))}',
        icon: Icons.star_rounded,
        demo: true,
        dense: dense,
        current: highlightCurrent && !selecting && currentId == null && demoOpen,
        selecting: selecting,
        onTap: selecting ? null : onOpenDemo,
        onRead: selecting || onRead == null ? null : () => onOpenDemo(),
      ),
    ]);
  }
}

String _words(int n) => '$n ${n == 1 ? 'word' : 'words'}';

/// One row. The icon tile turns into a check badge while selecting.
class _ScriptRow extends StatelessWidget {
  const _ScriptRow({
    required this.title,
    required this.meta,
    required this.icon,
    required this.dense,
    required this.current,
    required this.selecting,
    this.ticked = false,
    this.demo = false,
    this.onTap,
    this.onLongPress,
    this.onRead,
    this.menuItems,
    this.onMenu,
  });

  final String title;
  final String meta;
  final IconData icon;
  final bool demo;
  final bool dense;
  final bool current;
  final bool selecting;
  final bool ticked;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onRead;
  final List<PopupMenuEntry<String>> Function()? menuItems;
  final void Function(String)? onMenu;

  Future<void> _contextMenu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: menuItems!(),
    );
    if (choice != null) onMenu?.call(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tile = dense ? 32.0 : 40.0;
    final dimmed = selecting && demo;

    final Color fill = ticked
        ? scheme.primary
        : demo
            ? scheme.tertiaryContainer
            : scheme.surfaceContainerHighest;
    final Color ink = ticked
        ? scheme.onPrimary
        : demo
            ? scheme.onTertiaryContainer
            : scheme.onSurfaceVariant;

    final leading = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: tile,
      height: tile,
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(ticked ? tile / 2 : 12)),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(ticked ? Icons.check_rounded : icon, key: ValueKey(ticked), size: dense ? 18 : 22, color: ink),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Opacity(
        opacity: dimmed ? 0.4 : 1,
        child: GestureDetector(
          onSecondaryTapUp: menuItems == null ? null : (d) => _contextMenu(context, d.globalPosition),
          child: Material(
            color: ticked
                ? scheme.primary.withValues(alpha: 0.12)
                : current
                    ? scheme.primary.withValues(alpha: 0.14)
                    : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(dense ? 14 : 20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: EdgeInsets.fromLTRB(dense ? 10 : 14, dense ? 6 : 8, 4, dense ? 6 : 8),
                child: Row(children: [
                  leading,
                  SizedBox(width: dense ? 10 : 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: dense ? theme.textTheme.titleSmall : theme.textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Row(children: [
                          Flexible(
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (demo) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                              decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                              child: Text(
                                'DEMO',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ]),
                      ]),
                    ),
                  ),
                  if (onRead != null)
                    IconButton.filledTonal(tooltip: 'Start "$title"', icon: const Icon(Icons.play_arrow_rounded), onPressed: onRead),
                  if (menuItems != null)
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: Icon(Icons.more_horiz, size: dense ? 18 : 24),
                      onSelected: onMenu,
                      itemBuilder: (_) => menuItems!(),
                    ),
                  if (menuItems == null && onRead == null) SizedBox(width: dense ? 8 : 12),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Appears while selecting: how many are ticked, Select all, and Delete.
class ScriptSelectionBar extends ConsumerWidget {
  const ScriptSelectionBar({super.key, required this.history, this.onDeleted});
  final List<SavedScript> history;

  /// Called after a delete; [currentRemoved] is true when the script open in
  /// the editor was among those deleted.
  final void Function(bool currentRemoved)? onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final picked = ref.watch(scriptSelectionProvider);
    final selection = ref.read(scriptSelectionProvider.notifier);
    final chosen = [for (final s in history) if (picked?.contains(s.id) ?? false) s];
    final all = chosen.length == history.length;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: picked == null
          ? const SizedBox(width: double.infinity)
          : Material(
              color: scheme.surfaceContainerHigh,
              elevation: 3,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        chosen.isEmpty ? 'Tap scripts to select' : '${chosen.length} selected',
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => all ? selection.start() : selection.selectAll(history.map((s) => s.id)),
                      child: Text(all ? 'None' : 'All'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed: chosen.isEmpty
                          ? null
                          : () async {
                              final notifier = ref.read(studioProvider.notifier);
                              final open = notifier.currentId;
                              final openGoes = chosen.any((s) => s.id == open);
                              if (await confirmDeleteScripts(context, ref, chosen)) {
                                selection.clear();
                                onDeleted?.call(openGoes);
                              }
                            },
                      style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ]),
                ),
              ),
            ),
    );
  }
}
