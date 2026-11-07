#!/bin/zsh
# 编译并打包 build/Solune.app（ad-hoc 签名，仅本机使用）
#   ./scripts/build.sh           只打包
#   ./scripts/build.sh install   打包并安装到 ~/Applications
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Solune"
APP="build/Solune.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Solune"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 图标：Icon Composer 格式编译成 Assets.car，同时生成给旧系统用的 AppIcon.icns
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist build/icon-partial.plist --output-format human-readable-text > /dev/null
codesign --force --sign - "$APP"
echo "✓ $APP"

if [[ "${1:-}" == "install" ]]; then
  osascript -e 'tell application id "local.solune" to quit' 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Solune.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ 已安装到 ~/Applications/Solune.app"
fi
