#!/usr/bin/env bash
# Build MemPalacePlugin.bundle + ZIP for TypeWhisper (Apple Silicon only).
#
# Usage:
#   scripts/build-bundle.sh
#
# Output:
#   build/MemPalacePlugin.bundle    # macOS plugin bundle
#   build/MemPalacePlugin.zip       # zipped bundle for "Install from File"
#
# IMPORTANT: keep the release asset name `MemPalacePlugin.zip` stable across
# versions so the community-registry downloadURL doesn't have to change every
# release. Use a versioned RELEASE TITLE / TAG instead.

set -euo pipefail

# --- Args ---
# Apple Silicon only. TypeWhisper 1.4+ users are overwhelmingly on arm64
# and Intel builds add ~3x compile time + SDK build per arch.
ARCHS=("arm64")

# --- Paths ---
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_PATH="$ROOT/vendor/typewhisper-mac/TypeWhisperPluginSDK"
SRC_DIR="$ROOT/Sources/MemPalacePlugin"
MANIFEST="$SRC_DIR/manifest.json"
OUT_DIR="$ROOT/build"
BUNDLE="$OUT_DIR/MemPalacePlugin.bundle"

if [[ ! -d "$SDK_PATH" ]]; then
  echo "ERROR: TypeWhisperPluginSDK not found at $SDK_PATH" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

# Read version + bundle ID from manifest
VERSION=$(plutil -extract version raw -o - "$MANIFEST" 2>/dev/null || jq -r .version "$MANIFEST")
BUNDLE_ID=$(plutil -extract id raw -o - "$MANIFEST" 2>/dev/null || jq -r .id "$MANIFEST")
DISPLAY_NAME=$(plutil -extract name raw -o - "$MANIFEST" 2>/dev/null || jq -r .name "$MANIFEST")
PRINCIPAL=$(plutil -extract principalClass raw -o - "$MANIFEST" 2>/dev/null || jq -r .principalClass "$MANIFEST")

echo "=== Building $DISPLAY_NAME $VERSION ==="
echo "Bundle ID:       $BUNDLE_ID"
echo "Principal class: $PRINCIPAL"
echo "Architectures:   ${ARCHS[*]}"

# --- Step 1: Build SDK (release, arm64) ---
ARCH="${ARCHS[0]}"
echo ""
echo "--- Building TypeWhisperPluginSDK (release, $ARCH) ---"
(cd "$SDK_PATH" && swift build -c release --product TypeWhisperPluginSDK --arch "$ARCH") >/dev/null
SDK_RELEASE_DIR=$(find "$SDK_PATH/.build" -type d -path "*${ARCH}-apple-macosx/release" -maxdepth 3 | head -1)
if [[ -z "$SDK_RELEASE_DIR" ]] || [[ ! -e "$SDK_RELEASE_DIR/Modules/TypeWhisperPluginSDK.swiftmodule" ]]; then
  echo "ERROR: SDK swiftmodule for $ARCH not found under $SDK_PATH/.build" >&2
  exit 1
fi

# --- Step 2: Build per-arch Mach-O bundles ---
rm -rf "$OUT_DIR"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

ARCH_BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  echo ""
  echo "--- Compiling MemPalacePlugin ($ARCH) ---"
  ARCH_BIN="$OUT_DIR/MemPalacePlugin-$ARCH"

  swiftc \
    -O \
    -emit-library \
    -Xlinker -bundle \
    -module-name MemPalacePlugin \
    -target "$ARCH-apple-macos14.0" \
    -I "$SDK_RELEASE_DIR/Modules" \
    -L "$SDK_RELEASE_DIR" \
    -lTypeWhisperPluginSDK \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -Xlinker -rpath -Xlinker '@loader_path/../Frameworks' \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -o "$ARCH_BIN" \
    "$SRC_DIR"/*.swift

  ARCH_BINARIES+=("$ARCH_BIN")
done

# --- Step 3: lipo into universal if needed ---
if [[ ${#ARCH_BINARIES[@]} -gt 1 ]]; then
  echo ""
  echo "--- Creating universal binary ---"
  lipo -create "${ARCH_BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/MemPalacePlugin"
  rm -f "${ARCH_BINARIES[@]}"
else
  mv "${ARCH_BINARIES[0]}" "$BUNDLE/Contents/MacOS/MemPalacePlugin"
fi

# Strip install_name path so loader uses the bundle's resolved path
install_name_tool -id "@rpath/MemPalacePlugin" "$BUNDLE/Contents/MacOS/MemPalacePlugin" 2>/dev/null || true

# Rewrite SDK dylib reference to the framework path used by the host TypeWhisper.app.
# SwiftPM emits @rpath/libTypeWhisperPluginSDK.dylib; the running TypeWhisper provides
# @rpath/TypeWhisperPluginSDK.framework/Versions/A/TypeWhisperPluginSDK.
install_name_tool -change \
  "@rpath/libTypeWhisperPluginSDK.dylib" \
  "@rpath/TypeWhisperPluginSDK.framework/Versions/A/TypeWhisperPluginSDK" \
  "$BUNDLE/Contents/MacOS/MemPalacePlugin"

# --- Step 4: Copy manifest + write Info.plist ---
cp "$MANIFEST" "$BUNDLE/Contents/Resources/manifest.json"

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>MemPalacePlugin</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MemPalacePlugin</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>$PRINCIPAL</string>
</dict>
</plist>
EOF

# --- Step 5: Code sign ad-hoc ---
echo ""
echo "--- Code signing (ad-hoc) ---"
codesign --force --sign - --deep "$BUNDLE"
codesign --verify --strict "$BUNDLE"

# --- Step 6: Zip ---
echo ""
echo "--- Zipping bundle ---"
(cd "$OUT_DIR" && ditto -ck --sequesterRsrc --keepParent MemPalacePlugin.bundle MemPalacePlugin.zip)

echo ""
echo "=== DONE ==="
echo "Bundle:  $BUNDLE"
echo "ZIP:     $OUT_DIR/MemPalacePlugin.zip"
echo ""
echo "Install via TypeWhisper:"
echo "  Settings -> Integrations -> Install from File"
echo "  Pick:    $OUT_DIR/MemPalacePlugin.zip"
