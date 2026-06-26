#!/bin/bash
# ============================================================
#  TurboMix 构建脚本 v2.1
#  一键编译并打包为 macOS .app bundle
#  修复：
#  - 正确打包 ffmpeg 及其所有动态库依赖
#  - 修改 install_name 使 bundled ffmpeg 自包含
#  - 完善的代码签名
#
#  需要: Xcode Command Line Tools (swiftc)
#        Homebrew 安装的 ffmpeg (用于捆绑)
#
#  用法: chmod +x build.sh && ./build.sh
# ============================================================

set -e

APP_NAME="TurboMix"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="11.0"

echo "============================================"
echo "  TurboMix - 构建脚本 v2.1"
echo "  macOS arm64 / Apple Silicon 原生编译"
echo "  版本: $VERSION"
echo "============================================"

# 1. 清理旧构建
echo ""
echo "[1/7] 清理旧构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. 编译 Swift 源码
echo "[2/7] 编译 Swift 源码 (arm64, release)..."
cd "$PROJECT_DIR"

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
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -o "$BUILD_DIR/$APP_NAME" \
    $SOURCES

echo "  编译完成: $BUILD_DIR/$APP_NAME"

# 3. 创建 .app bundle 结构
echo "[3/7] 创建 .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制可执行文件
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 写入 Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.video.turbomix.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSMainStoryboardFile</key>
    <string></string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>视频文件</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>public.webm</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST_EOF

# 4. 打包 ffmpeg 及其动态库依赖
echo "[4/7] 打包 FFmpeg 及动态库依赖..."

FFMPEG_PATH=$(which ffmpeg 2>/dev/null || echo "")
FFPROBE_PATH=$(which ffprobe 2>/dev/null || echo "")

MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

if [ -n "$FFMPEG_PATH" ] && [ -n "$FFPROBE_PATH" ] && \
   [ -f "$FFMPEG_PATH" ] && [ -f "$FFPROBE_PATH" ]; then
    
    # 检查架构
    FFMPEG_ARCH=$(file "$FFMPEG_PATH" | grep -o "arm64|x86_64" | head -1)
    if [[ "$FFMPEG_ARCH" != *"arm64"* ]]; then
        echo "  ⚠️  警告: ffmpeg 架构 ($FFMPEG_ARCH) 可能与本机不匹配"
    fi
    
    echo "  复制 ffmpeg 和 ffprobe..."
    cp "$FFMPEG_PATH" "$MACOS_DIR/ffmpeg"
    cp "$FFPROBE_PATH" "$MACOS_DIR/ffprobe"
    chmod +x "$MACOS_DIR/ffmpeg" "$MACOS_DIR/ffprobe"
    
    # 使用 Python 脚本递归打包动态库依赖
    echo "  收集动态库依赖..."
    python3 "$PROJECT_DIR/scripts/bundle_ffmpeg.py" "$MACOS_DIR"
    
    echo "  ✅ FFmpeg 打包完成"
else
    echo "  ⚠️  未检测到 ffmpeg，运行时将使用系统 PATH 中的 ffmpeg"
    echo "  💡 建议: 运行 'brew install ffmpeg' 以捆绑 FFmpeg"
fi

# 5. 复制图标
echo "[5/7] 复制图标..."
ICON_SRC="$PROJECT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  图标已复制: AppIcon.icns"
else
    echo "  未找到自定义图标，使用系统默认"
fi

# 6. 代码签名
echo "[6/7] 代码签名 (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "  签名跳过（不影响使用）"

# 验证签名
if codesign -vvv "$APP_BUNDLE" 2>/dev/null; then
    echo "  ✅ 签名验证通过"
else
    echo "  ⚠️  签名验证失败（可能是 ad-hoc 签名的已知行为）"
fi

# 7. 复制到桌面
echo "[7/7] 部署到桌面..."
DESKTOP_APP="$HOME/Desktop/$APP_NAME.app"
rm -rf "$DESKTOP_APP"
cp -R "$APP_BUNDLE" "$DESKTOP_APP"

# 重新签名桌面上的副本
codesign --force --deep --sign - "$DESKTOP_APP" 2>/dev/null || true

echo ""
echo "============================================"
echo "  ✅ 构建完成！"
echo "  应用路径: $APP_BUNDLE"
echo "  桌面快捷: $DESKTOP_APP"
echo ""
echo "  双击运行或执行:"
echo "    open '$DESKTOP_APP'"
echo "============================================"

# 显示打包内容摘要
echo ""
echo "  打包内容摘要:"
echo "    - TurboMix 主程序"
if [ -f "$MACOS_DIR/ffmpeg" ]; then
    echo "    - ffmpeg + ffprobe"
    if [ -d "$MACOS_DIR/_dependencies" ] && [ "$(ls -A "$MACOS_DIR/_dependencies" 2>/dev/null)" ]; then
        LIB_COUNT=$(ls "$MACOS_DIR/_dependencies" | wc -l | tr -d ' ')
        echo "    - 动态库: $LIB_COUNT 个"
    fi
fi
echo "============================================"
