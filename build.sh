#!/bin/zsh
# Builds build/Ori Shader Warmer.app.
# Requires Xcode and mingw-w64 (brew install mingw-w64).
set -e; cd "${0:a:h}"
A="build/Ori Shader Warmer.app"; C="$A/Contents"; R="$C/Resources"
rm -rf build; mkdir -p "$C/MacOS" "$R"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13 src/main.swift -o "$C/MacOS/Ori Shader Warmer"
clang++ -std=c++17 -O2 -arch arm64 src/extract.cpp -o "$R/extract"
x86_64-w64-mingw32-g++ -std=c++17 -O2 src/oriwarm.cpp -o "$R/oriwarm_t.exe" -ld3d11 -ldxgi -ldxguid -static
cp src/warm.sh assets/AppIcon.icns assets/run.png recipe/plan.txt.gz "$R/"
cp assets/Info.plist "$C/"

# Signing: ad-hoc by default. For distribution set SIGN_ID to a "Developer ID Application" identity and
# NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials).
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$R/extract" "$A"
else
  codesign --force --deep -s - "$A"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  ditto -c -k --keepParent "$A" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$A"; rm build/notarize.zip
fi
ditto -c -k --keepParent "$A" "build/Ori-Shader-Warmer.zip"
echo "Built $A"
