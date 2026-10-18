#!/bin/sh
# Downloads the English sherpa-onnx models into assets/models/en/ (not in git).
# Check each model's licence before shipping and record it in THIRD_PARTY_NOTICES.
set -e
cd "$(dirname "$0")/../assets/models"
BASE=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models
ONLINE=sherpa-onnx-streaming-zipformer-en-20M-2023-02-17
OFFLINE=sherpa-onnx-zipformer-small-en-2023-06-26
mkdir -p en/online en/offline
for pair in "$ONLINE:online" "$OFFLINE:offline"; do
  name=${pair%%:*}; dest=${pair##*:}
  curl -fL "$BASE/$name.tar.bz2" | tar -xj -C en/$dest --strip-components=1
done
# keep only what the app loads (int8 encoder/joiner, fp32 decoder)
for d in online offline; do
  (cd en/$d
   mv encoder-*.int8.onnx encoder.int8.onnx
   mv joiner-*.int8.onnx joiner.int8.onnx
   mv decoder-*[0-9].onnx decoder.onnx
   rm -rf encoder-*.onnx joiner-*.onnx decoder-*.int8.onnx test_wavs *.md *.sh)
done
echo "Models ready in assets/models/en"
