/// Strips Markdown from a script the way the reference app does when a script is saved:
/// list markers, headings, quotes and inline formatting go, the words stay. Line by line;
/// fenced code keeps its text and loses only the fence lines.
String cleanScript(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <String>[];
  var inFence = false;
  for (var line in lines) {
    final start = _trimLeft(line);
    if (start.startsWith('```') || start.startsWith('~~~')) {
      inFence = !inFence;
      out.add('');
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    if (_linkDefinition.hasMatch(line) || _rule.hasMatch(line)) {
      out.add('');
      continue;
    }
    line = _dropMarker(_heading, line);
    while (_quote.hasMatch(line)) {
      line = _dropMarker(_quote, line);
    }
    line = _inline(_dropMarker(_numbered, _dropMarker(_bullet, line)));
    out.add(_trimRight(line));
  }
  return out.join('\n').trim();
}

final _linkDefinition = RegExp(r'^\s{0,3}\[[^\]]+\]:\s+\S+.*$');
final _heading = RegExp(r'^(\s{0,3})#{1,6}\s+');
final _quote = RegExp(r'^(\s{0,3})>\s?');
final _bullet = RegExp(r'^(\s*)[-+*]\s+');
final _numbered = RegExp(r'^(\s*)\d{1,9}[.)]\s+');
final _rule = RegExp(r'^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$');
final _htmlTag = RegExp(r'</?[A-Za-z][^>]*>');
final _autolink = RegExp(r'<((?:https?://|mailto:)[^>]+)>');
final _code = RegExp(r'(?<!\\)`([^`\n]+)`');
final _bold = RegExp(r'(?<!\\)\*\*(?=\S)(.+?)(?<=\S)(?<!\\)\*\*');
final _boldUnderscore = RegExp(r'(?<!\\)__(?=\S)(.+?)(?<=\S)(?<!\\)__');
final _strike = RegExp(r'(?<!\\)~~(?=\S)(.+?)(?<=\S)(?<!\\)~~');
final _italic = RegExp(r'(?<!\\)\*(?=\S)(.+?)(?<=\S)(?<!\\)\*');
final _italicUnderscore = RegExp(r'(?<![\\\p{L}\p{N}])_(?=\S)(.+?)(?<=\S)_(?![\p{L}\p{N}])', unicode: true);
final _escaped = RegExp(r'\\([\\`*{}\[\]()#+\-.!_>~])', unicode: true);
final _space = RegExp(r'\s');

/// Replaces the first match with its leading group (the indent), dropping the marker.
String _dropMarker(RegExp marker, String line) => line.replaceFirstMapped(marker, (m) => m[1]!);

String _trimLeft(String s) {
  var i = 0;
  while (i < s.length && _space.hasMatch(s[i])) {
    i++;
  }
  return s.substring(i);
}

String _trimRight(String s) {
  var i = s.length;
  while (i > 0 && _space.hasMatch(s[i - 1])) {
    i--;
  }
  return s.substring(0, i);
}

/// Index of the next unescaped `]` from [from], or -1.
int _closingBracket(int from, String s) {
  for (var i = from; i < s.length; i++) {
    if (s[i] == ']' && (i == 0 || s[i - 1] != '\\')) return i;
  }
  return -1;
}

/// Links and images keep their text; then HTML tags, code and emphasis markers and escapes go.
String _inline(String s) {
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    var open = -1;
    if (s[i] == '!' && i + 1 < s.length && s[i + 1] == '[') {
      open = i + 1;
    } else if (s[i] == '[') {
      open = i;
    }
    if (open < 0) {
      sb.write(s[i++]);
      continue;
    }
    final close = _closingBracket(open + 1, s);
    if (close < 0) {
      sb.write(s[i++]);
      continue;
    }
    var end = -1;
    final next = close + 1;
    if (next < s.length && s[next] == '(') {
      var depth = 0;
      for (var j = next; j < s.length; j++) {
        if (j <= next || s[j - 1] != '\\') {
          if (s[j] == '(') {
            depth++;
          } else if (s[j] == ')' && --depth == 0) {
            end = j;
            break;
          }
        }
      }
    } else if (next < s.length && s[next] == '[') {
      end = _closingBracket(close + 2, s);
    }
    if (end < 0) {
      sb.write(s[i++]);
      continue;
    }
    sb.write(_inline(s.substring(open + 1, close)));
    i = end + 1;
  }
  var r = sb.toString().replaceAllMapped(_autolink, (m) => m[1]!.replaceFirst(RegExp('^mailto:'), ''));
  r = r.replaceAll(_htmlTag, '');
  for (final p in [_code, _bold, _boldUnderscore, _strike, _italic, _italicUnderscore, _escaped]) {
    r = r.replaceAllMapped(p, (m) => m[1]!);
  }
  return r;
}
