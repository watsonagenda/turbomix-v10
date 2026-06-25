//  FFmpegService.swift — TurboMix v10 "Concurrency Safe"
//
//  核心引擎：ffprobe 分析 + ffmpeg concat 混剪
//  修复：
//  - stderrAccumulator 线程安全问题
//  - probeVideos 并发限制更精细
//  - 优化资源释放

import Foundation

final class FFmpegService {
    static let shared = FFmpegService()

    // MARK: - ffmpeg / ffprobe 路径

    private var ffmpegPath: String {
        let bundledPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil)
        if let bundled = bundledPath, FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // 通过系统 PATH 查找
        if let path = whichCommand("ffmpeg") {
            return path
        }
        return "ffmpeg"
    }

    private var ffprobePath: String {
        let bundledPath = Bundle.main.path(forResource: "ffprobe", ofType: nil)
        if let bundled = bundledPath, FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // 通过系统 PATH 查找
        if let path = whichCommand("ffprobe") {
            return path
        }
        return "ffprobe"
    }

    // MARK: - 视频信息分析

    func probeVideo(at url: URL) throws -> VideoItem {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            throw FFmpegError.probeFailed("无法解析 ffprobe 输出: \(url.lastPathComponent)")
        }

        let videoStream = streams.first { ($0["codec_type"] as? String) == "video" }

        let duration = Double(format["duration"] as? String ?? "0") ?? 0
        let size = Int64(format["size"] as? String ?? "0") ?? 0
        let bitRate = Int64(format["bit_rate"] as? String ?? "0") ?? 0

        let width = videoStream?["width"] as? Int ?? 0
        let height = videoStream?["height"] as? Int ?? 0
        let codec = videoStream?["codec_name"] as? String ?? "unknown"

        var frameRate = 30.0
        if let frStr = videoStream?["r_frame_rate"] as? String,
           frStr.contains("/") {
            let parts = frStr.split(separator: "/")
            if parts.count == 2,
               let num = Double(parts[0]),
               let den = Double(parts[1]),
               den != 0 {
                frameRate = num / den
            }
        } else if let fr = videoStream?["r_frame_rate"] as? String {
            frameRate = Double(fr) ?? 30.0
        }

        return VideoItem(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: size,
            duration: duration,
            width: width,
            height: height,
            codec: codec,
            bitRate: bitRate,
            frameRate: frameRate
        )
    }

    func probeVideos(urls: [URL], maxConcurrency: Int = 4, progress: @escaping (Int, Int) -> Void) async throws -> [VideoItem] {
        var results: [(index: Int, item: VideoItem)] = []
        results.reserveCapacity(urls.count)
        let total = urls.count
        var completed = 0
        // 分批处理，每批最多 maxConcurrency 个任务
        for chunk in urls.chunks(of: maxConcurrency) {
            var chunkResults: [(index: Int, item: VideoItem)] = []
            chunkResults.reserveCapacity(chunk.count)
            
            try await withThrowingTaskGroup(of: (Int, VideoItem).self) { group in
                for url in chunk {
                    let index = urls.firstIndex(of: url) ?? 0
                    group.addTask {
                        let item = try self.probeVideo(at: url)
                        return (index, item)
                    }
                }
                
                for try await result in group {
                    chunkResults.append(result)
                    completed += 1
                    let currentCompleted = completed
                    let currentTotal = total
                    
                    results.append(result)
                    
                    await MainActor.run {
                        progress(currentCompleted, currentTotal)
                    }
                }
            }
        }
        
        // 按原始顺序排序
        results.sort { $0.index < $1.index }
        return results.map { $0.item }
    }

    // MARK: - 混剪合成

    func mergeVideos(
        items: [VideoItem],
        outputURL: URL,
        config: MergeConfig,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        guard !items.isEmpty else {
            throw FFmpegError.mergeFailed("没有可合成的视频素材")
        }

        let workDir = outputURL.deletingLastPathComponent()
        let scriptPath = workDir.appendingPathComponent("turbo_mix_\(UUID().uuidString).sh")
        
        // 写入合并脚本
        let scriptContent = buildMergeScript(items: items, config: config, outputURL: outputURL)
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // 使用 Actor 保护 stderr 累积器
        actor StderrAccumulator {
            var text = ""
            func append(_ s: String) { text += s }
            func get() -> String { text }
        }
        let accumulator = StderrAccumulator()
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            
            Task {
                await accumulator.append(text)
            }
            
            if text.contains("out_time_ms="),
               let range = text.range(of: "out_time_ms=") {
                let valStr = text[text.index(after: range.upperBound)...]
                    .prefix(while: { $0.isNumber || $0 == "." })
                if let ms = Double(valStr) {
                    let seconds = ms / 1_000_000
                    let clamped = min((seconds / 3600) * 100, 100)
                    let detailMsg = "合成中... \(String(format: "%.1f", seconds))秒"
                    DispatchQueue.main.async {
                        progress(clamped, detailMsg)
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        
        // 删除临时脚本
        try? FileManager.default.removeItem(at: scriptPath)

        guard process.terminationStatus == 0 else {
            let errMsg = await accumulator.get()
            throw FFmpegError.mergeFailed("ffmpeg 合成失败 (退出码: \(process.terminationStatus)): \(errMsg.suffix(500))")
        }

        await MainActor.run { progress(100, "完成") }
    }
    
    private func buildMergeScript(items: [VideoItem], config: MergeConfig, outputURL: URL) -> String {
        var script = "#!/bin/bash\n"
        script += "set -e\n\n"
        
        // 构建 input list file
        let listPath = outputURL.deletingLastPathComponent()
            .appendingPathComponent("turbo_mix_inputs_\(UUID().uuidString).txt")
            .path
        
        var listContent = ""
        for item in items {
            let escapedPath = item.url.path.replacingOccurrences(of: "'", with: "'\\''")
            listContent += "file '\(escapedPath)'\n"
        }
        
        script += "cat > '\(listPath.replacingOccurrences(of: "'", with: "'\\''"))' << 'INPUTS_EOF'\n\(listContent)INPUTS_EOF\n\n"
        
        let ffmpeg = ffmpegPath
        var args = [ffmpeg]
        
        if config.outputQuality == .original {
            args.append(contentsOf: ["-f", "concat", "-safe", "0", "-i", listPath])
            args.append(contentsOf: ["-c", "copy"])
        } else {
            let crf = config.outputQuality.ffmpegCRF
            
            let filterChain = buildFilterChain(for: config)
            
            args.append(contentsOf: ["-f", "concat", "-safe", "0", "-i", listPath])
            
            if !config.enableAudio {
                args.append("-an")
            }
            
            if let filterChain = filterChain, !filterChain.isEmpty {
                args.append(contentsOf: ["-vf", filterChain])
            }
            
            if !crf.isEmpty {
                args.append(contentsOf: ["-crf", crf])
            } else {
                args.append(contentsOf: ["-q:v", "0"])
            }
        }
        
        args.append("-y")
        args.append(outputURL.path)
        
        let cmdParts = args.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
        script += "'\(cmdParts.joined(separator: "' '"))'\n"
        script += "\nrm -f '\(listPath.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        
        return script
    }

    // MARK: - 滤镜链构建

    private func buildFilterChain(for config: MergeConfig) -> String? {
        let targetAR = config.outputAspectRatio.ratio
        guard targetAR > 0 else { return nil }

        let fillColor: String
        switch config.fillMode {
        case .blackBars:  fillColor = "black"
        case .whiteBars:  fillColor = "white"
        default:          fillColor = "black"
        }

        switch config.fillMode {
        case .blackBars, .whiteBars:
            let pw = "(ow-ih*\(targetAR))/2"
            let ph = "0"
            return "scale=ih*\(targetAR):ih,pad=ih*\(targetAR):ih:\(pw):\(ph):\(fillColor)"

        case .cropFill:
            return "scale=ih*\(targetAR):ih,crop=ih*\(targetAR):ih"

        case .stretch:
            return "scale=ih*\(targetAR):ih"

        case .blur:
            return "scale=-1:ih,split[a][b];[a]scale=ih*\(targetAR):ih[c];[b]scale=ih*\(targetAR):ih,blend=all_mode='overlay',gblur=sigma=15[bg];[bg][c]overlay=(ow-iw)/2:(oh-ih)/2"
        }
    }

    // MARK: - 辅助


    private func whichCommand(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile() as Data
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }
        return nil
    }

    func checkAvailability() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func getVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: .newlines).first ?? "未知"
        } catch {
            return "未检测到 ffmpeg"
        }
    }
}


// MARK: - 数组扩展

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - 错误类型

enum FFmpegError: LocalizedError {
    case probeFailed(String)
    case mergeFailed(String)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .probeFailed(let msg):  return "视频分析失败: \(msg)"
        case .mergeFailed(let msg):  return "视频合成失败: \(msg)"
        case .notAvailable:          return "未找到 ffmpeg，请确保已安装"
        }
    }
}
