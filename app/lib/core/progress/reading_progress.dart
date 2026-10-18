enum WordState { completed, current, predicted, upcoming }

/// Presentation-agnostic word-level progress shared by Voice and Recorded
/// audio modes.
class PromptReadingProgress {
  const PromptReadingProgress({
    required this.confirmedWordIndex,
    this.predictedWordIndex,
    required this.dimsCompletedWords,
  });

  static const inactive = PromptReadingProgress(
    confirmedWordIndex: -1,
    dimsCompletedWords: false,
  );

  factory PromptReadingProgress.synchronized({
    required int confirmed,
    int? predicted,
  }) => PromptReadingProgress(
    confirmedWordIndex: confirmed,
    predictedWordIndex: predicted,
    dimsCompletedWords: true,
  );

  final int confirmedWordIndex;
  final int? predictedWordIndex;
  final bool dimsCompletedWords;

  WordState stateFor(int index) {
    if (dimsCompletedWords && confirmedWordIndex >= 0 && index < confirmedWordIndex) {
      return WordState.completed;
    }
    if (index == confirmedWordIndex) return WordState.current;
    if (predictedWordIndex != null && index == predictedWordIndex) {
      return WordState.predicted;
    }
    return WordState.upcoming;
  }

  @override
  bool operator ==(Object other) =>
      other is PromptReadingProgress &&
      other.confirmedWordIndex == confirmedWordIndex &&
      other.predictedWordIndex == predictedWordIndex &&
      other.dimsCompletedWords == dimsCompletedWords;

  @override
  int get hashCode =>
      Object.hash(confirmedWordIndex, predictedWordIndex, dimsCompletedWords);
}
