import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/external_links.dart';
import '../../services/providers.dart';
import 'studio_commands.dart';

/// The macOS menu bar. Items that need the Studio are disabled while the prompter is open; the
/// playback keys (Space, speed, restart) are global shortcuts, set in Settings › Shortcuts.
class AppMenuBar extends ConsumerWidget {
  const AppMenuBar({super.key, required this.child});
  final Widget child;

  static SingleActivator _cmd(LogicalKeyboardKey k, {bool shift = false, bool alt = false}) =>
      SingleActivator(k, meta: true, shift: shift, alt: alt);

  /// Edit actions go to whatever text field has focus, as the keys themselves do.
  static void _edit(Intent intent) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null) Actions.maybeInvoke(focus, intent);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(studioCommandsProvider);
    final settings = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;

    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'EchoPrompter', menus: [
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Settings…', shortcut: _cmd(LogicalKeyboardKey.comma), onSelected: c?.settings),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
        PlatformMenu(label: 'File', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'New Script', shortcut: _cmd(LogicalKeyboardKey.keyN), onSelected: c?.newScript),
            PlatformMenuItem(label: 'New Note', shortcut: _cmd(LogicalKeyboardKey.keyN, alt: true), onSelected: c?.newNote),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Import…', shortcut: _cmd(LogicalKeyboardKey.keyO), onSelected: c?.importFile),
            PlatformMenuItem(label: 'Export…', shortcut: _cmd(LogicalKeyboardKey.keyS, shift: true), onSelected: c?.exportFile),
            PlatformMenuItem(label: 'Save', shortcut: _cmd(LogicalKeyboardKey.keyS), onSelected: c?.save),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Show Scripts Folder', onSelected: c?.showScriptsFolder),
            PlatformMenuItem(label: 'Show Notes Folder', onSelected: c?.showNotesFolder),
          ]),
          PlatformMenuItemGroup(members: [
            // No key: ⌘⌫ already deletes to the start of the line while typing, and a script must never go that way.
            PlatformMenuItem(label: 'Delete Script…', onSelected: c?.deleteScript),
          ]),
        ]),
        PlatformMenu(label: 'Edit', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Undo', shortcut: _cmd(LogicalKeyboardKey.keyZ), onSelected: () => _edit(const UndoTextIntent(SelectionChangedCause.keyboard))),
            PlatformMenuItem(label: 'Redo', shortcut: _cmd(LogicalKeyboardKey.keyZ, shift: true), onSelected: () => _edit(const RedoTextIntent(SelectionChangedCause.keyboard))),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Cut', shortcut: _cmd(LogicalKeyboardKey.keyX), onSelected: () => _edit(CopySelectionTextIntent.cut(SelectionChangedCause.keyboard))),
            PlatformMenuItem(label: 'Copy', shortcut: _cmd(LogicalKeyboardKey.keyC), onSelected: () => _edit(CopySelectionTextIntent.copy)),
            PlatformMenuItem(label: 'Paste', shortcut: _cmd(LogicalKeyboardKey.keyV), onSelected: () => _edit(const PasteTextIntent(SelectionChangedCause.keyboard))),
            PlatformMenuItem(label: 'Select All', shortcut: _cmd(LogicalKeyboardKey.keyA), onSelected: () => _edit(const SelectAllTextIntent(SelectionChangedCause.keyboard))),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Insert Section', shortcut: _cmd(LogicalKeyboardKey.keyK), onSelected: c?.insertSection),
          ]),
        ]),
        PlatformMenu(label: 'View', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Show Scripts', onSelected: c?.showScripts),
            PlatformMenuItem(label: 'Show Notes', onSelected: c?.showNotes),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
        ]),
        PlatformMenu(label: 'Prompter', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Start Prompter', shortcut: const SingleActivator(LogicalKeyboardKey.enter, meta: true), onSelected: c?.start),
          ]),
          PlatformMenu(label: 'Follow', menus: [
            for (final m in PromptControlMode.values)
              PlatformMenuItem(
                label: m == settings.mode ? '✓ ${m.label}' : '    ${m.label}',
                onSelected: () => set((s) => s.copyWith(mode: m)),
              ),
          ]),
          PlatformMenu(label: 'Position', menus: [
            PlatformMenuItem(
              label: '${settings.placement == PromptPlacement.notch ? '✓ ' : '    '}Notch',
              onSelected: () => set((s) => s.copyWith(placement: PromptPlacement.notch)),
            ),
            for (final corner in PromptCorner.values)
              PlatformMenuItem(
                label: '${settings.placement == PromptPlacement.corner && settings.corner == corner ? '✓ ' : '    '}Corner: ${corner.label}',
                onSelected: () => set((s) => s.copyWith(placement: PromptPlacement.corner, corner: corner)),
              ),
            PlatformMenuItem(
              label: '${settings.placement == PromptPlacement.floating ? '✓ ' : '    '}Floating',
              onSelected: () => set((s) => s.copyWith(placement: PromptPlacement.floating)),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Reset Text Settings', onSelected: ref.read(settingsProvider.notifier).resetText),
          ]),
        ]),
        PlatformMenu(label: 'Window', menus: [
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
        ]),
        PlatformMenu(label: 'Help', menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'EchoPrompter Website & FAQ', onSelected: () => openExternal(Uri.parse(websiteUrl))),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Send Feedback…', onSelected: () => openExternal(feedbackMailto())),
            PlatformMenuItem(label: 'Copy Support Email', onSelected: () => Clipboard.setData(const ClipboardData(text: supportEmail))),
          ]),
        ]),
      ],
      child: child,
    );
  }
}
