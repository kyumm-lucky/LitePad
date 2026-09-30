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
# 应用图标（Info.plist 的 CFBundleIconFile 指向它；重新生成用 `make icon`）
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
# 声明简体中文本地化：系统提供的菜单（文件/编辑/显示/窗口/帮助）跟随中文
cp -R "Resources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP_DIR"

# 刷新系统的文档类型登记：新装的包改了 CFBundleDocumentTypes 后，「打开方式」列表
# 不一定立刻更新（未刷新时先重启 Finder 再看）。必须在签名之后跑 —— Info.plist 的
# 写入会破坏签名，改登记不会。
echo "==> 刷新文档类型登记"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 两种情况分开报：未找到只提示跳过，找到了但执行失败必须说出来 —— 登记没刷新时
# 「打开方式」列表不会更新，静默通过会让人以为已经登记好了。失败不中止构建：
# 应用本身已经装好了，登记只是锦上添花（`if !` 里的失败不触发 set -e）
if [ -x "$LSREGISTER" ]; then
    if ! "$LSREGISTER" -f "$APP_DIR"; then
        echo "lsregister 失败：文档类型登记未刷新，「打开方式」列表可能还是旧的（可重启 Finder 或重跑本脚本）"
    fi
else
    echo "（跳过：未找到 lsregister）"
fi

echo "✅ 完成: $APP_DIR"
