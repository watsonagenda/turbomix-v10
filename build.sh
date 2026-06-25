#!/bin/bash
# ============================================================
#  TurboMix 构建脚本
#  一键编译并打包为 macOS .app bundle
#
#  需要: Xcode Command Line Tools (swiftc)
#        Homebrew 安装的 ffmpeg (可选，运行时也可用)
#
#  用法: chmod +x build.sh && ./build.sh
# ============================================================

set -e

APP_NAME="TurboMix"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "============================================"
echo "  TurboMix - 构建脚本"
echo "  macOS arm64 / Apple Silicon 原生编译"
echo "============================================"

# 1. 清理旧构建
echo ""
echo "[1/5] 清理旧构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. 编译 Swift 源码
echo "[2/5] 编译 Swift 源码 (arm64, release)..."
cd "$PROJECT_DIR"

# 收集所有 Swift 源文件
SOURCES=$(find Sources -name "*.swift" -type f | sort)

swiftc \
    -target arm64-apple-macos14.0 \
    -O \
    -whole-module-optimization \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework UniformTypeIdentifiers \
    -framework Combine \
    -sdk $(xcrun --show-sdk-path --sdk macosx) \
    -o "$BUILD_DIR/$APP_NAME" \
    $SOURCES

echo "  编译完成: $BUILD_DIR/$APP_NAME"

# 3. 创建 .app bundle 结构
echo "[3/5] 创建 .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制可执行文件
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 复制 Info.plist
cp "$PROJECT_DIR/Sources/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 复制 ffmpeg（如果 Homebrew 安装了 arm64 版本）
FFMPEG_PATH="/opt/homebrew/bin/ffmpeg"
FFPROBE_PATH="/opt/homebrew/bin/ffprobe"
if [ -f "$FFMPEG_PATH" ] && [ -f "$FFPROBE_PATH" ]; then
    echo "  检测到 arm64 原生 ffmpeg，捆绑到 .app 中..."
    cp "$FFMPEG_PATH" "$APP_BUNDLE/Contents/MacOS/ffmpeg"
    cp "$FFPROBE_PATH" "$APP_BUNDLE/Contents/MacOS/ffprobe"
    chmod +x "$APP_BUNDLE/Contents/MacOS/ffmpeg"
    chmod +x "$APP_BUNDLE/Contents/MacOS/ffprobe"
    echo "  ffmpeg 已捆绑"
else
    echo "  未检测到 /opt/homebrew/bin/ffmpeg，运行时将使用系统 PATH 中的 ffmpeg"
fi

# 4. 复制图标
echo "[4/5] 复制图标..."
ICON_SRC="$PROJECT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  图标已复制: AppIcon.icns"
else
    echo "  未找到自定义图标，使用系统默认"
fi

# 5. 签名（仅 ad-hoc，开发用）
echo "[5/5] 代码签名 (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "  签名跳过（不影响使用）"

echo ""
echo "============================================"
echo "  构建完成！"
echo "  应用路径: $APP_BUNDLE"
echo ""
echo "  双击运行或执行:"
echo "    open '$APP_BUNDLE'"
echo "============================================"

# 自动复制到桌面
DESKTOP_APP="$HOME/Desktop/$APP_NAME.app"
rm -rf "$DESKTOP_APP"
cp -R "$APP_BUNDLE" "$DESKTOP_APP"
echo "已复制到: $DESKTOP_APP"
