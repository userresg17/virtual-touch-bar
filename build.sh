#!/bin/zsh
# Compila o Virtual Touch Bar e monta o bundle .app
set -e
cd "$(dirname "$0")"

APP="VirtualTouchBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VirtualTouchBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.internal.virtualtouchbar</string>
    <key>CFBundleName</key>
    <string>Virtual Touch Bar</string>
    <key>CFBundleDisplayName</key>
    <string>Virtual Touch Bar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>O amplificador aplica ganho ao áudio do sistema para aumentar o volume na saída Bluetooth.</string>
</dict>
</plist>
PLIST

swiftc -O -framework Cocoa -framework ServiceManagement -framework IOKit -framework CoreAudio -framework AudioToolbox *.swift -o "$APP/Contents/MacOS/VirtualTouchBar"

# Assinatura com identidade local estável (certificado "VirtualTouchBar Local"
# no chaveiro). Isso mantém a MESMA identidade de código a cada rebuild, então
# o macOS não derruba as permissões de Acessibilidade/Monitorização de Entrada.
# Se o certificado não existir, cai de volta na assinatura ad-hoc (-s -).
SIGN_ID="VirtualTouchBar Local"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    SIGN_ID="-"
fi

# Helper das ventoinhas (instalado como setuid root no primeiro uso)
clang -O2 -framework IOKit smcfan.c -o "$APP/Contents/Resources/smcfan"
codesign --force -s "$SIGN_ID" "$APP/Contents/Resources/smcfan"

codesign --force -s "$SIGN_ID" --identifier com.internal.virtualtouchbar "$APP"

echo "Pronto: $(pwd)/$APP"
