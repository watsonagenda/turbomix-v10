//  VideoMergeViewModel.swift — TurboMix v11
//
//  UI层与服务层的桥梁
//  管理所有状态、处理用户交互、驱动混剪流程
//
//  修复：
//  - 添加文件夹时递归收集视频文件
//  - 限制并发 probe 数量，防止大量文件卡死
//  - 更好的错误处理和用户反馈
//  - 使用现代 NSOpenPanel.begin(completionHandler:) API

import SwiftUI
import Combine

@MainActor
final class VideoMergeViewModel: ObservableObject {

    // MARK: - 发布属性

    @Published var videoItems: [VideoItem] = []
    @Published var status: MergeStatus = .idle
    @Published var minDurationSeconds: Double = 60
    @Published var quality: MergeConfig.OutputQuality = .original
    @Published var enableAudio: Bool = true
    @Published var outputAspectRatio: MergeConfig.AspectRatio = .original
    @Published var fillMode: MergeConfig.FillMode = .blackBars
    @Published var scaleToFit: Bool = true
    @Published var progressValue: Double = 0
    @Published var progressDetail: String = ""
    @Published var outputURL: URL?
    @Published var errorMessage: String = ""

    // 输出设置
    @Published var outputDirectory: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    @Published var outputFileName: String = "混剪视频"
    @Published var openOutputWhenDone: Bool = true

    // 历史记录
    @Published var recentOutputs: [URL] = []

    // 撤销删除栈
    @Published var removedVideosStack: [(VideoItem, Int)] = []

    // MARK: - 计算属性

    var totalDuration: Double {
        ShuffleEngine().estimatedTotalDuration(videoItems)
    }

    var formattedTotalDuration: String {
        formatSeconds(totalDuration)
    }

    var minDurationFormatted: String {
        formatSeconds(minDurationSeconds)
    }

    var maxSliderValue: Double {
        max(totalDuration, minDurationSeconds + 10)
    }

    var isProcessing: Bool {
        status != .idle && status != .completed && status != .failed
    }

    var config: MergeConfig {
        MergeConfig(
            minDuration: minDurationSeconds,
            enableAudio: enableAudio,
            outputQuality: quality,
            outputAspectRatio: outputAspectRatio,
            fillMode: fillMode,
            scaleToFit: scaleToFit
        )
    }

    var outputDirectoryDisplayName: String {
        outputDirectory.lastPathComponent
    }

    /// 构建完整输出路径（确保不覆盖已有文件）
    var resolvedOutputURL: URL {
        var base = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "混剪视频" }

        var url = outputDirectory.appendingPathComponent("\(base).mp4")
        var counter = 2

        while FileManager.default.fileExists(atPath: url.path) {
            url = outputDirectory.appendingPathComponent("\(base)_\(counter).mp4")
            counter += 1
        }

        return url
    }

    // MARK: - Services

    private let ffmpegService = FFmpegService.shared
    private let shuffleEngine = ShuffleEngine()

    // MARK: - 初始化

    init() {
        // 恢复上次使用的输出目录
        if let bookmark = UserDefaults.standard.data(forKey: "lastOutputDirectory"),
           let url = resolveBookmark(bookmark) {
            outputDirectory = url
        }
    }

    // MARK: - 输出目录操作

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择输出目录"
        panel.message = "请选择混剪视频的保存位置"
        panel.prompt = "选择"
        panel.canCreateDirectories = true

        panel.begin { [weak self] result in
            guard result == .OK,
                  let selectedUrl = panel.url else { return }
            self?.outputDirectory = selectedUrl
            self?.saveBookmark(for: selectedUrl)
        }
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: "lastOutputDirectory")
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else { return nil }
        return url
    }

    // MARK: - 素材操作

    func addVideos(urls: [URL]) async {
        // 防止重复添加
        guard !urls.isEmpty else { return }
        
        // 如果是文件夹，递归收集其中的视频文件
        var allUrls: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                let videos = collectVideoFiles(from: url)
                allUrls.append(contentsOf: videos)
            } else {
                if SupportedFormats.isVideoFile(url) {
                    allUrls.append(url)
                }
            }
        }
        
        if allUrls.isEmpty {
            errorMessage = "没有找到有效的视频文件"
            status = .failed
            return
        }
        
        // 过滤掉已存在的文件
        let existingURLs = Set(videoItems.map { $0.url })
        let newURLs = allUrls.filter { !existingURLs.contains($0) }
        
        if newURLs.isEmpty {
            errorMessage = "所选文件已全部在素材列表中"
            status = .failed
            return
        }
        
        status = .scanning

        do {
            let items = try await ffmpegService.probeVideos(
                urls: newURLs,
                maxConcurrency: 4
            ) { completed, total in
                self.status = .analyzing
                self.progressValue = Double(completed) / Double(max(total, 1)) * 100
                self.progressDetail = "分析中 \(completed)/\(total)"
            }

            videoItems.append(contentsOf: items)
            status = .idle
            progressValue = 0
            progressDetail = ""
            errorMessage = ""
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
        }
    }

    /// 递归收集文件夹中的视频文件
    private func collectVideoFiles(from folderURL: URL) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        for case let fileURL as URL in enumerator {
            if SupportedFormats.isVideoFile(fileURL) {
                result.append(fileURL)
            }
        }
        return result
    }

    func removeVideo(at index: Int) {
        guard index < videoItems.count else { return }
        let item = videoItems[index]
        removedVideosStack.append((item, index))
        videoItems.remove(at: index)
    }

    func clearAllVideos() {
        for (index, item) in videoItems.enumerated().reversed() {
            removedVideosStack.append((item, index))
        }
        videoItems.removeAll()
        status = .idle
        progressValue = 0
        progressDetail = ""
        errorMessage = ""
    }

    func reshuffle() {
        guard videoItems.count >= 2 else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            videoItems = shuffleEngine.shuffle(videoItems)
        }
    }

    func undoRemove() {
        guard let (item, originalIndex) = removedVideosStack.popLast() else { return }
        let safeIndex = min(originalIndex, videoItems.count)
        videoItems.insert(item, at: safeIndex)
        removedVideosStack.removeAll()
    }

    var hasRemovedVideos: Bool { !removedVideosStack.isEmpty }

    var lastRemovedName: String { removedVideosStack.last?.0.fileName ?? "" }

    // MARK: - 混剪

    func startRandomMerge() async {
        guard !videoItems.isEmpty else { return }

        status = .shuffling
        progressValue = 0
        outputURL = nil
        errorMessage = ""

        let selectedItems = shuffleEngine.generateRandomSequence(
            from: videoItems,
            minDuration: config.minDuration
        )

        let url = resolvedOutputURL

        status = .merging
        progressValue = 0

        do {
            try await ffmpegService.mergeVideos(
                items: selectedItems,
                outputURL: url,
                config: config
            ) { progress, detail in
                self.progressValue = progress
                self.progressDetail = detail
            }

            self.outputURL = url
            self.status = .completed
            self.progressValue = 100

            // 记录历史
            recentOutputs.insert(url, at: 0)
            if recentOutputs.count > 10 { recentOutputs = Array(recentOutputs.prefix(10)) }

            // 自动打开
            if openOutputWhenDone {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            self.status = .failed
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 辅助

    private func formatSeconds(_ seconds: Double) -> String {
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        if mins > 0 {
            return "\(mins)分\(secs)秒"
        }
        return "\(secs)秒"
    }
}
