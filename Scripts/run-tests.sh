#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
OUT="$ROOT/work/easyshop-self-test"
mkdir -p "$ROOT/work/module-cache"

env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$ROOT/work/module-cache" \
swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macosx14.0 \
    -parse-as-library \
    "$ROOT/Sources/EasyshopApp/Models/EditorModels.swift" \
    "$ROOT/Sources/EasyshopApp/Services/ImageData.swift" \
    "$ROOT/Sources/EasyshopApp/Services/SelectionEngine.swift" \
    "$ROOT/Sources/EasyshopApp/Services/ResizeEngine.swift" \
    "$ROOT/Sources/EasyshopApp/Services/AIEngine.swift" \
    "$ROOT/Sources/EasyshopApp/Services/RenderEngine.swift" \
    "$ROOT/Sources/EasyshopApp/Services/PSDWriter.swift" \
    "$ROOT/Sources/EasyshopApp/Services/ProjectIO.swift" \
    "$ROOT/Tests/SelfTest.swift" \
    -framework AppKit \
    -framework CoreImage \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -framework Vision \
    -o "$OUT"

"$OUT"
