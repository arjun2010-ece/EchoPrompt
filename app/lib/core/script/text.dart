final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _whitespace = RegExp(r'\s+', unicode: true);

/// Lowercases [word] and strips everything except letters and digits.
/// Single copy of the POC's duplicated `normalized(_:)`.
String normalizeWord(String word) => word
    .toLowerCase()
    .runes
    .map(String.fromCharCode)
    .where(_letterOrDigit.hasMatch)
    .join();

final _blankLineRun = RegExp(r'[ \t]*(?:\r?\n[ \t]*){3,}');

/// [script] with any run of two or more blank lines cut to a single blank
/// line. Only for display: word positions are unchanged, and a single blank
/// line, or none, is left as written.
String tidyBlankLines(String script) => script.replaceAll(_blankLineRun, '\n\n');

/// Script words as displayed: split on whitespace, punctuation kept.
List<String> scriptWords(String script) =>
    script.split(_whitespace).where((w) => w.isNotEmpty).toList();

/// Words as recognised/spoken: lowercased, split on non letter/digit.
List<String> spokenWords(String text) =>
    text.toLowerCase().split(_nonWord).where((w) => w.isNotEmpty).toList();

/// Whether a script word matches a normalised spoken word. Words of four or
/// more characters may match as a substring (partial recognition).
bool wordsMatch(String scriptWord, String spokenWord) {
  final expected = normalizeWord(scriptWord);
  return expected == spokenWord ||
      (spokenWord.length >= 4 && expected.contains(spokenWord));
}
