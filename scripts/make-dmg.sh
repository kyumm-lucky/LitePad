#!/bin/bash
# 基于已构建的 LitePad.app 生成可分发 DMG（含指向 /Applications 的拖拽安装链接）
set -euo pipefail

APP_NAME="LitePad"
VERSION="0.1.0"
cd "$(dirname "$0")/.."
DMG_NAME="build/$APP_NAME-$VERSION.dmg"

if [ ! -d "build/$APP_NAME.app" ]; then
    echo "请先运行 scripts/make-app.sh 生成 $APP_NAME.app"
    exit 1
fi

STAGING="build/dmg-staging"
rm -rf "$STAGING" "$DMG_NAME"
mkdir -p "$STAGING"
cp -R "build/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil 创建 DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"
rm -rf "$STAGING"

echo "✅ 完成: $DMG_NAME"
