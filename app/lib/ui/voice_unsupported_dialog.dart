import 'package:flutter/material.dart';

/// Tells the reader that Voice mode can't run on this device: neither its on-device recogniser nor its system
/// recogniser can be used.
Future<void> showVoiceUnsupportedDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    icon: const Icon(Icons.mic_off_rounded, size: 32),
    title: const Text('Voice mode isn\'t available on this device'),
    content: const Text(
      'It needs the device\'s speech recognition, and this device doesn\'t offer it for English yet. '
      'If it should, the device may still be downloading the English speech files, or speech recognition may be turned off for EchoPrompter in Settings: try again in a few minutes.\n\n'
      'Normal mode still scrolls at the pace you set.',
    ),
    actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Got it'))],
  ),
);
