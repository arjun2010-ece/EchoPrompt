/// Analytics seam (plan §10.1). Phase 3 adds Firebase / Measurement Protocol
/// sinks. Never pass script text, titles, file names or transcripts.
abstract class AnalyticsSink {
  void log(String name, Map<String, Object> params);
}

class NoopSink implements AnalyticsSink {
  const NoopSink();
  @override
  void log(String name, Map<String, Object> params) {}
}

class AnalyticsService {
  AnalyticsService([this.sink = const NoopSink()]);
  AnalyticsSink sink;

  void log(String name, [Map<String, Object> params = const {}]) =>
      sink.log(name, params);

  static String wordsBucket(int words) => words < 100
      ? '<100'
      : words < 500
      ? '100-500'
      : words < 2000
      ? '500-2k'
      : '2k+';
}
