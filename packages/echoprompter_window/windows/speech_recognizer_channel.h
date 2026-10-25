#ifndef FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_
#define FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace echoprompter_window {

// Voice and Audio mode's recogniser on Windows: the on-device SAPI dictation recogniser, streaming partial
// hypotheses to Dart while the event stream is listened to. It is the counterpart of the Android, iOS and
// macOS recognisers, so Dart treats all of them the same: every hypothesis goes to the script tracker, and an
// empty final marks the start of a session and each phrase's end.
//
// It needs no internet connection or Settings switch, and listens to the system's default input, which
// Windows points at a headset when one is connected. SAPI posts a window message when it has events, so
// everything here runs on the platform thread.
class SpeechRecognizerChannel {
 public:
  explicit SpeechRecognizerChannel(flutter::PluginRegistrarWindows *registrar);
  ~SpeechRecognizerChannel();

  SpeechRecognizerChannel(const SpeechRecognizerChannel &) = delete;
  SpeechRecognizerChannel &operator=(const SpeechRecognizerChannel &) = delete;

 private:
  class Impl;  // keeps the SAPI headers out of the plugin's other sources
  std::unique_ptr<Impl> impl_;
};

}  // namespace echoprompter_window

#endif  // FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_
