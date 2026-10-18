# Windows equivalent of fetch_models.sh. Downloads the same English models.
# Model assets and the download cache are ignored by Git.
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $appRoot 'build/model-downloads'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$base = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models'
$models = @{
    online = 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17'
    offline = 'sherpa-onnx-zipformer-small-en-2023-06-26'
}
foreach ($mode in @('online', 'offline')) {
    $name = $models[$mode]
    $archive = Join-Path $cache "$name.tar.bz2"
    $destination = Join-Path $appRoot "assets/models/en/$mode"
    Write-Host "Downloading $mode English speech model..."
    & curl.exe --fail --location --retry 3 --output $archive "$base/$name.tar.bz2"
    if ($LASTEXITCODE -ne 0) { throw "Download failed for $mode" }
    $entries = @(& tar.exe -tjf $archive)
    if ($LASTEXITCODE -ne 0) { throw "Cannot read model archive: $archive" }
    $files = @{
        'encoder.int8.onnx' = '/encoder[^/]*\.int8\.onnx$'
        'decoder.onnx' = '/decoder[^/]*(?<!\.int8)\.onnx$'
        'joiner.int8.onnx' = '/joiner[^/]*\.int8\.onnx$'
        'tokens.txt' = '/tokens\.txt$'
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    foreach ($outputName in $files.Keys) {
        $matchesInArchive = @($entries | Where-Object { $_ -match $files[$outputName] })
        if ($matchesInArchive.Count -ne 1) {
            throw "Expected one $outputName in $archive, found $($matchesInArchive.Count)"
        }
        & tar.exe -xjf $archive -C $cache $matchesInArchive[0]
        if ($LASTEXITCODE -ne 0) { throw "Cannot extract $outputName" }
        $source = Join-Path $cache $matchesInArchive[0]
        if ((Get-Item -LiteralPath $source).Length -eq 0) { throw "Empty model file: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $destination $outputName) -Force
    }
    Write-Host "$mode model ready."
}
Write-Host 'Models ready in assets/models/en. Rebuild the Windows app to bundle them.'