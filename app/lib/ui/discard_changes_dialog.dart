import 'package:flutter/material.dart';

/// Asks whether to throw away unsaved script edits; true if the user agrees.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text('Your edits to this script have not been saved.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep editing')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Discard')),
      ],
    ),
  );
  return discard ?? false;
}
