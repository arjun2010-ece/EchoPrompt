#include "speech_recognizer_channel.h"

#include <unknwn.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Media.SpeechRecognition.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdio>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>

namespace echoprompter_window {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncAction;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Globalization::Language;
using namespace winrt::Windows::Media::SpeechRecognition;

namespace {

constexpr UINT kTasksMessage = WM_APP + 2;  // the tray icon uses WM_APP + 1
constexpr UINT_PTR kRestartTimer = 0x5350;
constexpr int kMaxFailures = 5;
// "The speech privacy policy was not accepted": Online speech recognition is off in Windows settings.
constexpr int32_t kPrivacyNotAccepted = static_cast<int32_t>(0x80045509);
// The speech language (English) isn't installed.
constexpr int32_t kLanguageNotSupported = static_cast<int32_t>(0x8004503A);

// Work the WinRT callbacks (which run on other threads) leave for the platform thread. It outlives the channel,
// so a callback that fires while the channel is being destroyed never touches freed memory.
struct Shared {
  std::mutex mutex;
  std::deque<std::function<void()>> tasks;
  std::atomic<HWND> hwnd{nullptr};
};

void PostTask(const std::shared_ptr<Shared> &shared, std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->tasks.push_back(std::move(task));
  }
  const HWND hwnd = shared->hwnd.load();
  if (hwnd) PostMessageW(hwnd, kTasksMessage, 0, 0);
}

}  // namespace

class SpeechRecognizerChannel::Impl {
 public:
  using Sink = flutter::EventSink<EncodableValue>;
  using HandlerError = flutter::StreamHandlerError<EncodableValue>;

  explicit Impl(flutter::PluginRegistrarWindows *registrar)
      : registrar_(registrar), shared_(std::make_shared<Shared>()) {
    method_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "com.echoprompter/speech",
        &flutter::StandardMethodCodec::GetInstance());
    method_->SetMethodCallHandler([this](const auto &call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "com.echoprompter/speech/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
        [this](const EncodableValue *, std::unique_ptr<Sink> &&events) { return Listen(std::move(events)); },
        [this](const EncodableValue *) { return Cancel(); }));
    proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return WindowProc(hwnd, message, wparam, lparam);
        });
  }

  ~Impl() {
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
    Stop();
  }

 private:
  void HandleMethodCall(const flutter::MethodCall<EncodableValue> &call,
                        std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto &name = call.method_name();
    if (name == "isAvailable") {
      result->Success(EncodableValue(Available()));
    } else if (name == "setBias") {
      result->Success();  // dictation takes no phrase hints
    } else {
      result->NotImplemented();
    }
  }

  // English can be recognised on this PC. Permission problems show up when listening starts, with a message.
  bool Available() {
    try {
      SpeechRecognizer probe{Language(L"en-US")};
      probe.Close();
      return true;
    } catch (winrt::hresult_error const &) {
      return false;
    }
  }

  std::unique_ptr<HandlerError> Listen(std::unique_ptr<Sink> &&events) {
    sink_ = std::move(events);
    running_ = true;
    failures_ = 0;
    shared_->hwnd.store(Hwnd());
    BeginSession();
    return nullptr;
  }

  std::unique_ptr<HandlerError> Cancel() {
    Stop();
    sink_.reset();
    return nullptr;
  }

  HWND Hwnd() const {
    auto *view = registrar_->GetView();
    return view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
  }

  // --- Sessions -----------------------------------------------------------------------

  void BeginSession() {
    if (!running_) return;
    ReleaseRecognizer();
    const int id = ++session_;
    try {
      recognizer_ = SpeechRecognizer(Language(L"en-US"));
      recognizer_.Constraints().Append(
          SpeechRecognitionTopicConstraint(SpeechRecognitionScenario::Dictation, L"dictation"));
    } catch (winrt::hresult_error const &e) {
      FailFrom(static_cast<int32_t>(e.code()));
      return;
    }
    auto shared = shared_;
    hypothesis_revoker_ = recognizer_.HypothesisGenerated(
        winrt::auto_revoke,
        [this, id, shared](SpeechRecognizer const &, SpeechRecognitionHypothesisGeneratedEventArgs const &args) {
          std::string text = winrt::to_string(args.Hypothesis().Text());
          if (text.empty()) return;
          PostTask(shared, [this, id, text]() {
            if (id == session_) Emit(text, false);
          });
        });
    recognizer_.CompileConstraintsAsync().Completed(
        [this, id, shared](IAsyncOperation<SpeechRecognitionCompilationResult> const &op, AsyncStatus status) {
          SpeechRecognitionResultStatus result = SpeechRecognitionResultStatus::Unknown;
          int32_t error = 0;
          if (status == AsyncStatus::Completed) {
            try {
              result = op.GetResults().Status();
            } catch (winrt::hresult_error const &e) {
              error = static_cast<int32_t>(e.code());
            }
          } else {
            error = static_cast<int32_t>(op.ErrorCode());
          }
          PostTask(shared, [this, id, result, error]() {
            if (id == session_) OnCompiled(result, error);
          });
        });
  }

  void OnCompiled(SpeechRecognitionResultStatus result, int32_t error) {
    if (error != 0) return FailFrom(error);
    if (result != SpeechRecognitionResultStatus::Success) return OnSessionEnded(result);
    StartContinuous();
  }

  void StartContinuous() {
    const int id = session_;
    auto shared = shared_;
    try {
      auto session = recognizer_.ContinuousRecognitionSession();
      result_revoker_ = session.ResultGenerated(
          winrt::auto_revoke,
          [this, id, shared](SpeechContinuousRecognitionSession const &,
                             SpeechContinuousRecognitionResultGeneratedEventArgs const &args) {
            std::string text = winrt::to_string(args.Result().Text());
            if (text.empty()) return;
            PostTask(shared, [this, id, text]() {
              if (id != session_) return;
              failures_ = 0;
              Emit(text, true);
            });
          });
      completed_revoker_ = session.Completed(
          winrt::auto_revoke,
          [this, id, shared](SpeechContinuousRecognitionSession const &,
                             SpeechContinuousRecognitionCompletedEventArgs const &args) {
            const SpeechRecognitionResultStatus status = args.Status();
            PostTask(shared, [this, id, status]() {
              if (id == session_) OnSessionEnded(status);
            });
          });
      // An empty final at the start of a session, so the tracker re-anchors.
      Emit("", true);
      session.StartAsync().Completed([this, id, shared](IAsyncAction const &op, AsyncStatus status) {
        if (status == AsyncStatus::Completed) return;
        const int32_t error = static_cast<int32_t>(op.ErrorCode());
        PostTask(shared, [this, id, error]() {
          if (id == session_) FailFrom(error);
        });
      });
    } catch (winrt::hresult_error const &e) {
      FailFrom(static_cast<int32_t>(e.code()));
    }
  }

  // The recogniser ends a continuous session on its own after a stretch of silence; Dart wants one unbroken
  // stream, so most endings just start the next session.
  void OnSessionEnded(SpeechRecognitionResultStatus status) {
    switch (status) {
      case SpeechRecognitionResultStatus::Success:
      case SpeechRecognitionResultStatus::TimeoutExceeded:
      case SpeechRecognitionResultStatus::PauseLimitExceeded:
        ScheduleRestart(100);
        break;
      case SpeechRecognitionResultStatus::MicrophoneUnavailable:
        Fatal("unavailable",
              "The microphone isn't available. In Settings > Privacy & security > Microphone, let desktop apps use it.");
        break;
      case SpeechRecognitionResultStatus::NetworkFailure:
        Fatal("unavailable", "Speech recognition needs an internet connection on this PC.");
        break;
      case SpeechRecognitionResultStatus::TopicLanguageNotSupported:
      case SpeechRecognitionResultStatus::GrammarLanguageMismatch:
        Fatal("language", "Speech recognition can't recognise English on this PC.");
        break;
      default:
        Failed();
        break;
    }
  }

  // One more failure in a row; five give up.
  void Failed() {
    if (++failures_ >= kMaxFailures) {
      Fatal("unavailable", "Speech recognition is not responding");
      return;
    }
    ScheduleRestart(400);
  }

  void FailFrom(int32_t error) {
    if (error == kPrivacyNotAccepted) {
      Fatal("unavailable",
            "Turn on Online speech recognition in Settings > Privacy & security > Speech to use Voice mode.");
    } else if (error == kLanguageNotSupported) {
      Fatal("language",
            "Speech recognition can't recognise English on this PC. Add the English (US) speech language in "
            "Settings > Time & language.");
    } else {
      char code[16];
      std::snprintf(code, sizeof(code), "0x%08X", static_cast<unsigned int>(error));
      if (++failures_ >= kMaxFailures) {
        Fatal("unavailable", std::string("Speech recognition couldn't start (") + code + ")");
      } else {
        ScheduleRestart(400);
      }
    }
  }

  void ScheduleRestart(UINT delay_ms) {
    ++session_;  // whatever the ended session still reports is stale
    ReleaseRecognizer();
    if (!running_) return;
    const HWND hwnd = Hwnd();
    if (hwnd) {
      SetTimer(hwnd, kRestartTimer, delay_ms, nullptr);
    } else {
      BeginSession();
    }
  }

  void Fatal(const char *code, const std::string &message) {
    if (sink_) sink_->Error(code, message);
    Stop();
  }

  void Stop() {
    running_ = false;
    ++session_;
    const HWND hwnd = Hwnd();
    if (hwnd) KillTimer(hwnd, kRestartTimer);
    ReleaseRecognizer();
  }

  void ReleaseRecognizer() {
    hypothesis_revoker_.revoke();
    result_revoker_.revoke();
    completed_revoker_.revoke();
    if (recognizer_) {
      try {
        recognizer_.ContinuousRecognitionSession().CancelAsync();
        recognizer_.Close();
      } catch (winrt::hresult_error const &) {
      }
      recognizer_ = nullptr;
    }
  }

  void Emit(const std::string &text, bool is_final) {
    if (!sink_) return;
    EncodableMap hypothesis;
    hypothesis[EncodableValue("text")] = EncodableValue(text);
    hypothesis[EncodableValue("final")] = EncodableValue(is_final);
    sink_->Success(EncodableValue(hypothesis));
  }

  // --- Platform thread ----------------------------------------------------------------

  void Drain() {
    std::deque<std::function<void()>> batch;
    {
      std::lock_guard<std::mutex> lock(shared_->mutex);
      batch.swap(shared_->tasks);
    }
    for (auto &task : batch) task();
  }

  std::optional<LRESULT> WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM) {
    if (message == kTasksMessage) {
      Drain();
      return 0;
    }
    if (message == WM_TIMER && wparam == kRestartTimer) {
      KillTimer(hwnd, kRestartTimer);
      BeginSession();
      return 0;
    }
    return std::nullopt;
  }

  flutter::PluginRegistrarWindows *registrar_;
  std::shared_ptr<Shared> shared_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<Sink> sink_;
  int proc_id_ = -1;

  bool running_ = false;  // listening: the stream has a listener
  int session_ = 0;       // bumped whenever a session ends; callbacks of older ones are ignored
  int failures_ = 0;      // consecutive failures; five give up

  SpeechRecognizer recognizer_{nullptr};
  SpeechRecognizer::HypothesisGenerated_revoker hypothesis_revoker_;
  SpeechContinuousRecognitionSession::ResultGenerated_revoker result_revoker_;
  SpeechContinuousRecognitionSession::Completed_revoker completed_revoker_;
};

SpeechRecognizerChannel::SpeechRecognizerChannel(flutter::PluginRegistrarWindows *registrar)
    : impl_(std::make_unique<Impl>(registrar)) {}

SpeechRecognizerChannel::~SpeechRecognizerChannel() = default;

}  // namespace echoprompter_window
