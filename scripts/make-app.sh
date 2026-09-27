#!/bin/bash
# 编译 release 二进制并组装成 LitePad.app（ad-hoc 签名，本机可直接运行）
set -euo pipefail

APP_NAME="LitePad"
cd "$(dirname "$0")/.."

echo "==> swift build (release)"
swift build -c release

BINARY=".build/release/$APP_NAME"
APP_DIR="build/$APP_NAME.app"

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# 声明简体中文本地化：系统提供的菜单（文件/编辑/显示/窗口/帮助）跟随中文
cp -R "Resources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP_DIR"

echo "✅ 完成: $APP_DIR"
