# TurboMix

基于 FFmpeg 的智能视频混剪工具，专为 macOS 原生设计。

## 功能特性

- 🎬 智能视频混剪 - 自动打乱素材顺序，生成全新的混剪视频
- 🔄 随机洗牌算法 - Fisher-Yates 算法确保每次结果不同
- 🖥️ 原生 macOS 设计 - 适配现代 macOS 外观风格
- 📱 多比例支持 - 支持横屏、竖屏、方形等多种视频比例
- 🎵 音频控制 - 可选择是否保留原始音频
- 📊 实时预览 - 混剪进度实时显示

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon (M1/M2/M3/M4) 原生支持

## 安装

1. 从 [Releases](https://github.com/username/turbomix/releases) 页面下载最新的 `.dmg` 安装包
2. 双击打开 DMG 文件
3. 将 TurboMix 拖入 Applications 文件夹
4. 打开应用

## 依赖

TurboMix 需要 FFmpeg 来处理视频。应用会自动检测以下位置的 FFmpeg：

- 应用捆绑包内的 FFmpeg（推荐）
- 系统 PATH 中的 FFmpeg

### 安装 FFmpeg

如果系统未安装 FFmpeg，可以通过以下方式安装：

```bash
# 使用 Homebrew
brew install ffmpeg
```

## 使用方法

### 图形界面

1. 启动 TurboMix
2. 点击"添加文件"或"添加文件夹"导入视频素材
3. 也可以直接将视频文件拖放到应用窗口中
4. 在右侧面板设置混剪参数：
   - 最小输出时长
   - 输出质量
   - 画面比例
   - 填充模式
5. 点击"开始混剪"按钮

### 命令行界面 (CLI)

```bash
# 查看系统状态
python3 turbo_mix_cli.py status

# 查看视频信息
python3 turbo_mix_cli.py info /path/to/video.mp4

# 扫描目录中的视频文件
python3 turbo_mix_cli.py scan /path/to/videos

# 添加素材
python3 turbo_mix_cli.py add /path/to/video1.mp4 /path/to/video2.mp4
python3 turbo_mix_cli.py add-folder /path/to/videos

# 开始混剪
python3 turbo_mix_cli.py merge --min-duration 120 --quality high --aspect-ratio tiktok9by16

# 管理操作
python3 turbo_mix_cli.py shuffle    # 重新随机排序
python3 turbo_mix_cli.py clear      # 清空素材
python3 turbo_mix_cli.py export-config  # 导出当前配置
```

## 项目结构

```
TurboMix/
├── Sources/              # Swift 源代码
│   ├── QuickCutVideoApp.swift    # 应用入口
│   ├── Models/
│   │   └── VideoItem.swift       # 视频数据模型
│   ├── Services/
│   │   ├── FFmpegService.swift   # FFmpeg 集成服务
│   │   └── ShuffleEngine.swift   # 随机混剪引擎
│   ├── ViewModels/
│   │   └── VideoMergeViewModel.swift  # 视图模型
│   └── Views/
│       ├── ContentView.swift         # 主界面
│       ├── DesignSystem.swift        # 设计规范
│       └── DropZoneView.swift        # 拖放区域
├── Resources/
│   └── AppIcon.icns              # 应用图标
├── CLI/
│   └── turbo_mix_cli.py          # 命令行工具
├── Package.swift                 # Swift 包配置
└── build.sh                      # 构建脚本
```

## 构建

### 使用构建脚本

```bash
chmod +x build.sh
./build.sh
```

### 使用 Swift Package Manager

```bash
swift build
```

## 技术栈

- **语言**: Swift 5.9+
- **框架**: SwiftUI, AppKit, Combine
- **视频处理**: FFmpeg
- **包管理**: Swift Package Manager

## 许可证

MIT License

## 致谢

- [FFmpeg](https://ffmpeg.org/) - 强大的多媒体框架
- [SwiftUI](https://developer.apple.com/documentation/swiftui) - 现代 UI 框架
