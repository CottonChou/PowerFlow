#!/bin/sh
# 构建 PowerFlow.app（ad-hoc 签名，无 Developer ID 公证）
set -eu

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/PowerFlow.app"
SCRATCH=".build"

echo "==> 编译 ($CONFIG)"
swift build -c "$CONFIG" --product PowerFlow --scratch-path "$SCRATCH"

BIN="$(swift build -c "$CONFIG" --product PowerFlow --scratch-path "$SCRATCH" --show-bin-path)/PowerFlow"
if [ ! -x "$BIN" ]; then
    echo "找不到产物: $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PowerFlow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>PowerFlow</string>
    <key>CFBundleIdentifier</key>
    <string>io.powerflow.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PowerFlow</string>
    <key>CFBundleDisplayName</key>
    <string>PowerFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>本机只读采样，无网络传输</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
    echo "签名失败（ad-hoc 失败不影响本地运行，但 Gatekeeper 会更严格）" >&2
}

echo "==> 完成: $APP"
echo "运行: open $APP"
echo "诊断: $(swift build -c "$CONFIG" --product powerflow-probe --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null || echo .build/release)/powerflow-probe --rounds 3"
