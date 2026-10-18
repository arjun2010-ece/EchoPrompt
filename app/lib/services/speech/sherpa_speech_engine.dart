import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/matching/audio_aligner.dart';
import '../../core/script/text.dart';
import 'model_store.dart';
import 'speech_engine.dart';

/// On-device recognition with sherpa-onnx: a streaming transducer for Voice
/// mode and an offline transducer with token timestamps for Recorded audio.
class SherpaSpeechEngine implements SpeechEngine {
  sherpa.OnlineRecognizer? _online;
  sherpa.OfflineRecognizer? _offline;
  String? _dir;

  @override
  Future<void> init() async {
    if (_dir != null) return;
    final dir = await ModelStore.english();
    if (dir == null) {
      throw SpeechUnavailable(
        'Speech model not installed. Run tools/fetch_models.sh and rebuild.',
      );
    }
    sherpa.initBindings();
    _dir = dir.path;
  }

  sherpa.OnlineRecognizer _onlineRecognizer() => _online ??= () {
    final d = p.join(_dir!, 'online');
    return sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: p.join(d, 'encoder.int8.onnx'),
            decoder: p.join(d, 'decoder.onnx'),
            joiner: p.join(d, 'joiner.int8.onnx'),
          ),
          tokens: p.join(d, 'tokens.txt'),
          numThreads: 2,
          debug: false,
        ),
        rule1MinTrailingSilence: 1.0,
        rule2MinTrailingSilence: 0.6,
      ),
    );
  }();

  sherpa.OfflineRecognizer _offlineRecognizer() => _offline ??= () {
    final d = p.join(_dir!, 'offline');
    return sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: p.join(d, 'encoder.int8.onnx'),
            decoder: p.join(d, 'decoder.onnx'),
            joiner: p.join(d, 'joiner.int8.onnx'),
          ),
          tokens: p.join(d, 'tokens.txt'),
          numThreads: 2,
          debug: false,
        ),
      ),
    );
  }();

  @override
  Stream<List<String>> listen(Stream<Float32List> samples) async* {
    final rec = _onlineRecognizer();
    final stream = rec.createStream();
    var emitted = 0;
    try {
      await for (final chunk in samples) {
        stream.acceptWaveform(samples: chunk, sampleRate: 16000);
        while (rec.isReady(stream)) {
          rec.decode(stream);
        }
        final words = spokenWords(rec.getResult(stream).text);
        final fresh = newWordsSince(words, emitted);
        if (fresh.isNotEmpty) {
          emitted = words.length;
          yield fresh;
        }
        if (rec.isEndpoint(stream)) {
          rec.reset(stream);
          emitted = 0;
        }
      }
    } finally {
      stream.free();
    }
  }

  @override
  Future<List<TranscriptSegment>> transcribeFile(String path) async {
    final rec = _offlineRecognizer();
    final wave = sherpa.readWave(path);
    if (wave.samples.isEmpty) throw SpeechUnavailable('Could not read audio file');
    final stream = rec.createStream();
    try {
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      rec.decode(stream);
      final r = rec.getResult(stream);
      return groupTokensIntoWords(
        r.tokens,
        r.timestamps,
        endTime: wave.samples.length / wave.sampleRate,
      );
    } finally {
      stream.free();
    }
  }

  @override
  Future<void> dispose() async {
    _online?.free();
    _offline?.free();
    _online = _offline = null;
  }
}
