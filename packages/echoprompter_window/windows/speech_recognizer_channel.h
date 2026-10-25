#ifndef FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_
#define FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace echoprompter_window {

// Voice and Audio mode's recogniser on Windows: `Windows.Media.SpeechRecognition` in continuous dictation,
// streaming partial hypotheses to Dart while the event stream is listened to. It is the counterpart of the
// Android, iOS and macOS recognisers, so Dart treats all of them the same: every hypothesis goes to the script
// tracker, and an empty final marks the start of a session and each phrase's end.
//
// The recogniser listens to the system's default input, which Windows points at a headset when one is
// connected. The WinRT API cannot choose another device. Everything here runs on the platform thread; the
// WinRT callbacks only queue work for it.
class SpeechRecognizerChannel {
 public:
  explicit SpeechRecognizerChannel(flutter::PluginRegistrarWindows *registrar);
  ~SpeechRecognizerChannel();

  SpeechRecognizerChannel(const SpeechRecognizerChannel &) = delete;
  SpeechRecognizerChannel &operator=(const SpeechRecognizerChannel &) = delete;

 private:
  class Impl;  // keeps the WinRT headers out of the plugin's other sources
  std::unique_ptr<Impl> impl_;
};

}  // namespace echoprompter_window

#endif  // FLUTTER_PLUGIN_ECHOPROMPTER_SPEECH_RECOGNIZER_CHANNEL_H_
