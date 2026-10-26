import 'package:flutter/material.dart';

import '../../core/script/sections.dart';

/// The script editor's controller: section marker lines (`[Intro]`) show in a dimmer, bolder style
/// so the structure of a long script is easy to see while typing.
class ScriptTextController extends TextEditingController {
  ScriptTextController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final markers = sectionMarkers(text);
    // While an input method is composing, leave the text to the default so its underline stays right.
    if (markers.isEmpty || (withComposing && value.composing.isValid && !value.composing.isCollapsed)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final marker = (style ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final children = <InlineSpan>[];
    var at = 0;
    for (final m in markers) {
      if (m.start > at) children.add(TextSpan(text: text.substring(at, m.start)));
      children.add(TextSpan(text: text.substring(m.start, m.end), style: marker));
      at = m.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: children);
  }
}
