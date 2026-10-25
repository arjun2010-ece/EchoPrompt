#include "speech_recognizer_channel.h"

#include <windows.h>

#include <sapi.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace echoprompter_window {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kSapiMessage = WM_APP + 3;  // the tray icon uses WM_APP + 1
constexpr UINT_PTR kHoldTimer = 0x5348;
constexpr UINT kHoldMs = 150;

std::string Utf8(const wchar_t *text) {
  if (!text || !*text) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return std::string();
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  out.resize(static_cast<size_t>(size - 1));
  return out;
}

}  // namespace

class SpeechRecognizerChannel::Impl {
 public:
  using Sink = flutter::EventSink<EncodableValue>;
  using HandlerError = flutter::StreamHandlerError<EncodableValue>;

  explicit Impl(flutter::PluginRegistrarWindows *registrar) : registrar_(registrar) {
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
      SetVocabulary(call.arguments());
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  // An English recogniser is installed. Microphone problems show up when listening starts.
  bool Available() {
    ComPtr<ISpRecognizer> probe;
    return SUCCEEDED(CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&probe))) &&
           EnglishRecognizer() != nullptr;
  }

  // The recogniser to use: the PC's default is whatever speech language it is set to, and the app only knows
  // English. US English first, then British, then any English.
  static ComPtr<ISpObjectToken> EnglishRecognizer() {
    ComPtr<ISpObjectTokenCategory> category;
    if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&category))) ||
        FAILED(category->SetId(SPCAT_RECOGNIZERS, FALSE))) {
      return nullptr;
    }
    for (const wchar_t *language : {L"Language=409", L"Language=809", L"Language=9"}) {
      ComPtr<IEnumSpObjectTokens> tokens;
      ULONG count = 0;
      ComPtr<ISpObjectToken> token;
      if (SUCCEEDED(category->EnumTokens(language, nullptr, &tokens)) && SUCCEEDED(tokens->GetCount(&count)) &&
          count > 0 && SUCCEEDED(tokens->Item(0, &token))) {
        return token;
      }
    }
    return nullptr;
  }

  std::unique_ptr<HandlerError> Listen(std::unique_ptr<Sink> &&events) {
    sink_ = std::move(events);
    Stop();
    // An empty final at the start of a session, so the tracker re-anchors.
    Emit("", true);
    Start();
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

  // --- Recogniser ---------------------------------------------------------------------

  // Dictation on the in-process recogniser, listening to the default microphone. The recogniser keeps running
  // through silence, so Dart gets one unbroken stream of hypotheses and finals without any restarting.
  void Start() {
    const HWND hwnd = Hwnd();
    if (!hwnd) return Fatal("unavailable", "Speech recognition couldn't start (no window)");
    hwnd_ = hwnd;

    HRESULT hr = CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&recognizer_));
    if (FAILED(hr)) return Fail("Windows speech recognition is not installed on this PC", hr);
    const ComPtr<ISpObjectToken> english = EnglishRecognizer();
    if (!english || FAILED(recognizer_->SetRecognizer(english.Get()))) {
      return Fatal("language", "Speech recognition can't recognise English on this PC. Install an English speech "
                               "language in Settings > Time & language > Speech.");
    }

    ComPtr<ISpMMSysAudio> audio;
    hr = CoCreateInstance(CLSID_SpMMAudioIn, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&audio));
    if (SUCCEEDED(hr)) hr = audio->SetDeviceId(WAVE_MAPPER);  // the system's default input
    if (FAILED(hr)) return Fail("The microphone isn't available", hr);
    hr = recognizer_->SetInput(audio.Get(), TRUE);
    if (FAILED(hr)) return Fail("The microphone isn't available", hr);

    hr = recognizer_->CreateRecoContext(&context_);
    if (FAILED(hr)) return Fail("Speech recognition couldn't start", hr);
    context_->SetNotifyWindowMessage(hwnd, kSapiMessage, 0, 0);
    const ULONGLONG events = SPFEI(SPEI_HYPOTHESIS) | SPFEI(SPEI_RECOGNITION);
    context_->SetInterest(events, events);

    hr = context_->CreateGrammar(1, &grammar_);
    if (SUCCEEDED(hr)) hr = grammar_->LoadDictation(nullptr, SPLO_STATIC);
    if (SUCCEEDED(hr)) hr = context_->CreateGrammar(2, &script_grammar_);
    if (FAILED(hr)) return Fail("Speech recognition can't recognise English on this PC", hr);
    ApplyVocabulary();
    hr = recognizer_->SetRecoState(SPRST_ACTIVE);
    if (FAILED(hr)) return Fail("The microphone isn't available", hr);
  }

  // The words the reader is about to say, from the script ahead of the cursor (Dart sends them before listening
  // starts and after every phrase). Recognising only these is far more accurate than open dictation, which has
  // to guess from the whole language. Without any, open dictation listens instead.
  void SetVocabulary(const EncodableValue *arguments) {
    std::set<std::wstring> words;
    if (const auto *list = arguments ? std::get_if<flutter::EncodableList>(arguments) : nullptr) {
      for (const auto &item : *list) {
        const auto *text = std::get_if<std::string>(&item);
        if (!text || text->empty()) continue;
        const int size = MultiByteToWideChar(CP_UTF8, 0, text->c_str(), -1, nullptr, 0);
        if (size <= 1) continue;
        std::wstring word(static_cast<size_t>(size), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, text->c_str(), -1, word.data(), size);
        word.resize(static_cast<size_t>(size - 1));
        words.insert(std::move(word));
      }
    }
    if (words == vocabulary_) return;
    vocabulary_ = std::move(words);
    if (context_) ApplyVocabulary();
  }

  // Listens with the script's words when they are known and the recogniser accepts some, else to open dictation.
  void ApplyVocabulary() {
    if (!grammar_ || !script_grammar_) return;
    const bool scripted = !vocabulary_.empty() && BuildScriptGrammar();
    script_grammar_->SetRuleState(L"script", nullptr, scripted ? SPRS_ACTIVE : SPRS_INACTIVE);
    grammar_->SetDictationState(scripted ? SPRS_INACTIVE : SPRS_ACTIVE);
  }

  // One rule that accepts any run of the vocabulary's words. False if the recogniser knows none of them.
  bool BuildScriptGrammar() {
    SPSTATEHANDLE start = nullptr;
    if (FAILED(script_grammar_->GetRule(L"script", 0, SPRAF_TopLevel | SPRAF_Active | SPRAF_Dynamic, TRUE, &start))) {
      return false;
    }
    script_grammar_->ClearRule(start);
    SPSTATEHANDLE loop = nullptr;
    if (FAILED(script_grammar_->CreateNewState(start, &loop))) return false;
    int added = 0;
    for (const auto &word : vocabulary_) {
      // A word the recogniser can't pronounce is left out.
      if (FAILED(script_grammar_->AddWordTransition(start, loop, word.c_str(), L" ", SPWT_LEXICAL, 1.0f, nullptr))) {
        continue;
      }
      script_grammar_->AddWordTransition(loop, loop, word.c_str(), L" ", SPWT_LEXICAL, 1.0f, nullptr);
      ++added;
    }
    if (added == 0) return false;
    script_grammar_->AddWordTransition(loop, nullptr, nullptr, nullptr, SPWT_LEXICAL, 1.0f, nullptr);  // may end here
    return SUCCEEDED(script_grammar_->Commit(0));
  }

  void Stop() {
    CancelHold();
    previous_.clear();
    sent_.clear();
    if (grammar_) grammar_->SetDictationState(SPRS_INACTIVE);
    if (script_grammar_) script_grammar_->SetRuleState(L"script", nullptr, SPRS_INACTIVE);
    if (context_) context_->SetNotifySink(nullptr);
    script_grammar_.Reset();
    grammar_.Reset();
    context_.Reset();
    recognizer_.Reset();
  }

  void Fail(const char *message, HRESULT hr) {
    char code[16];
    std::snprintf(code, sizeof(code), "0x%08X", static_cast<unsigned int>(hr));
    Fatal("unavailable", std::string(message) + " (" + code + ")");
  }

  void Fatal(const char *code, const std::string &message) {
    if (sink_) sink_->Error(code, message);
    Stop();
  }

  // Reads what the recogniser has reported since the last message.
  void Drain() {
    if (!context_) return;
    SPEVENT event;
    ULONG fetched = 0;
    while (context_ && SUCCEEDED(context_->GetEvents(1, &event, &fetched)) && fetched == 1) {
      const bool is_final = event.eEventId == SPEI_RECOGNITION;
      const bool is_hypothesis = event.eEventId == SPEI_HYPOTHESIS;
      if ((is_final || is_hypothesis) && event.elParamType == SPET_LPARAM_IS_OBJECT && event.lParam) {
        auto *result = reinterpret_cast<ISpRecoResult *>(event.lParam);
        wchar_t *text = nullptr;
        if (SUCCEEDED(result->GetText(static_cast<ULONG>(SP_GETWHOLEPHRASE), static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE, &text,
                            nullptr)) && text) {
          const std::string utf8 = Utf8(text);
          if (!utf8.empty()) OnPhrase(utf8, is_final);
          CoTaskMemFree(text);
        }
      }
      if (event.elParamType == SPET_LPARAM_IS_OBJECT && event.lParam) {
        reinterpret_cast<IUnknown *>(event.lParam)->Release();
      } else if (event.elParamType == SPET_LPARAM_IS_POINTER && event.lParam) {
        CoTaskMemFree(reinterpret_cast<void *>(event.lParam));
      } else if (event.elParamType == SPET_LPARAM_IS_STRING && event.lParam) {
        CoTaskMemFree(reinterpret_cast<void *>(event.lParam));
      } else if (event.elParamType == SPET_LPARAM_IS_TOKEN && event.lParam) {
        reinterpret_cast<IUnknown *>(event.lParam)->Release();
      }
    }
  }

  // The recogniser revises a running hypothesis as it hears more, and a recogniser that may only say the script's
  // words fills any stray sound (a breath, the start of the next word) with one of them. The script tracker moves
  // on a single matching word, so such a word would send the highlight ahead and it could not come back. A
  // hypothesis therefore reaches Dart in two steps: the words it shares with the one before at once, and the
  // rest once nothing has revised them for [kHoldMs]. A final is complete and goes straight through.
  void OnPhrase(const std::string &text, bool is_final) {
    if (is_final) {
      CancelHold();
      previous_.clear();
      sent_.clear();
      Emit(text, true);
      return;
    }
    const std::vector<std::string> words = Split(text);
    std::vector<std::string> stable;
    for (size_t i = 0; i < words.size() && i < previous_.size() && words[i] == previous_[i]; ++i) {
      stable.push_back(words[i]);
    }
    previous_ = words;
    SendPartial(Join(stable));
    pending_ = text;
    if (hwnd_) SetTimer(hwnd_, kHoldTimer, kHoldMs, nullptr);  // restarts the wait
  }

  void SendPartial(const std::string &text) {
    if (text.empty() || text == sent_) return;
    sent_ = text;
    Emit(text, false);
  }

  void CancelHold() {
    if (hwnd_) KillTimer(hwnd_, kHoldTimer);
    pending_.clear();
  }

  static std::vector<std::string> Split(const std::string &text) {
    std::vector<std::string> words;
    size_t start = 0;
    while (start < text.size()) {
      const size_t end = text.find(' ', start);
      const size_t stop = end == std::string::npos ? text.size() : end;
      if (stop > start) words.push_back(text.substr(start, stop - start));
      start = stop + 1;
    }
    return words;
  }

  static std::string Join(const std::vector<std::string> &words) {
    std::string out;
    for (const auto &w : words) out += (out.empty() ? "" : " ") + w;
    return out;
  }

  void Emit(const std::string &text, bool is_final) {
    if (!sink_) return;
    EncodableMap hypothesis;
    hypothesis[EncodableValue("text")] = EncodableValue(text);
    hypothesis[EncodableValue("final")] = EncodableValue(is_final);
    sink_->Success(EncodableValue(hypothesis));
  }

  std::optional<LRESULT> WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM) {
    if (message == kSapiMessage) {
      Drain();
      return 0;
    }
    if (message == WM_TIMER && wparam == kHoldTimer && hwnd == hwnd_) {
      const std::string text = pending_;
      CancelHold();
      SendPartial(text);
      return 0;
    }
    return std::nullopt;
  }

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<Sink> sink_;
  int proc_id_ = -1;

  ComPtr<ISpRecognizer> recognizer_;
  ComPtr<ISpRecoContext> context_;
  ComPtr<ISpRecoGrammar> grammar_;         // open dictation
  ComPtr<ISpRecoGrammar> script_grammar_;  // only the script's words
  std::set<std::wstring> vocabulary_;

  HWND hwnd_ = nullptr;
  std::vector<std::string> previous_;  // the last hypothesis, word by word
  std::string sent_;                   // what Dart last got from the running phrase
  std::string pending_;                // the newest hypothesis, waiting out the hold
};

SpeechRecognizerChannel::SpeechRecognizerChannel(flutter::PluginRegistrarWindows *registrar)
    : impl_(std::make_unique<Impl>(registrar)) {}

SpeechRecognizerChannel::~SpeechRecognizerChannel() = default;

}  // namespace echoprompter_window
