# sherpa_onnx_windows 1.13.8 ships x64 DLLs even for ARM64 Flutter builds.
# Replace only the Windows ARM64 bundle with the matching upstream C API.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  include(FetchContent)
  FetchContent_Declare(echoprompter_sherpa_arm64
    URL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-win-arm64-shared-MT-Release-lib.tar.bz2"
    URL_HASH SHA256=22cd2b2b5e35c1132abc74a91ee77f683645437382617af6a4bd5818b9c509f4
  )
  FetchContent_MakeAvailable(echoprompter_sherpa_arm64)
  file(GLOB_RECURSE ECHOPROMPTER_SPEECH_DLLS
    "${echoprompter_sherpa_arm64_SOURCE_DIR}/*.dll")
  if(NOT ECHOPROMPTER_SPEECH_DLLS)
    message(FATAL_ERROR "Windows ARM64 speech libraries are missing")
  endif()
  list(REMOVE_ITEM PLUGIN_BUNDLED_LIBRARIES ${sherpa_onnx_windows_bundled_libraries})
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${ECHOPROMPTER_SPEECH_DLLS})
endif()