import 'package:echoprompter/core/progress/reading_progress.dart';
import 'package:echoprompter/core/script/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizeWord is Unicode-aware', () {
    expect(normalizeWord('Hello,'), 'hello');
    expect(normalizeWord('Café!'), 'café');
    expect(normalizeWord('...'), '');
  });

  test('reading progress states', () {
    final p = PromptReadingProgress.synchronized(confirmed: 3, predicted: 4);
    expect(p.stateFor(1), WordState.completed);
    expect(p.stateFor(3), WordState.current);
    expect(p.stateFor(4), WordState.predicted);
    expect(p.stateFor(9), WordState.upcoming);
  });
}
