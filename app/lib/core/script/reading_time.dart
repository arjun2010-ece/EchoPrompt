import 'text.dart';

/// Spoken pace used for Voice and Audio modes, where the speaker sets the speed.
const spokenWordsPerMinute = 150;

int wordCount(String script) => scriptWords(script).length;

/// Rough reading time, e.g. `under a minute`, `~3 min`, `~1 h 05 min`.
String readingTimeLabel(int words, {double wordsPerMinute = 150}) {
  if (words == 0) return '';
  final minutes = words / wordsPerMinute;
  if (minutes < 1) return 'under a minute';
  final m = minutes.round();
  if (m < 60) return '~$m min';
  return '~${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}

/// Word index (into [scriptWords]) closest to character [offset].
int wordIndexAtOffset(String script, int offset) {
  var index = 0;
  for (final m in RegExp(r'\S+').allMatches(script)) {
    if (m.end >= offset) return index;
    index++;
  }
  return index == 0 ? 0 : index - 1;
}

/// Character offset of the start of word [index].
int offsetOfWord(String script, int index) {
  var i = 0;
  for (final m in RegExp(r'\S+').allMatches(script)) {
    if (i == index) return m.start;
    i++;
  }
  return script.length;
}

/// "Today 14:03", "Yesterday 09:12", "12 Oct", "12 Oct 2024".
String friendlyDate(DateTime when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = DateTime(when.year, when.month, when.day);
  final today = DateTime(n.year, n.month, n.day);
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(when.hour)}:${two(when.minute)}';
  final days = today.difference(d).inDays;
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Yesterday $time';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${when.day} ${months[when.month - 1]}';
  return when.year == n.year ? date : '$date ${when.year}';
}
