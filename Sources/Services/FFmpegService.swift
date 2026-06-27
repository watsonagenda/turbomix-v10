//  FFmpegService.swift — TurboMix v11
//
//  核心引擎：ffprobe 分析 + ffmpeg concat 混剪

import Foundation

final class FFmpegService {
    static let shared = FFmpegService()

    // MARK: - ffmpeg / ffprobe 路径

    private var bundleMacOSPath: String {
        let bundlePath = Bundle.main.bundlePath as NSString
        let contentsPath = bundlePath.appendingPathComponent("Contents") as String
        return (contentsPath as NSString).appendingPathComponent("MacOS")
    }

    private var ffmpegPath: String {
        let bundledPath = "\(bundleMacOSPath)/ffmpeg"
        if FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }
        if let path = whichCommand("ffmpeg") {
            return path
        }
        return "ffmpeg"
    }

    private var ffprobePath: String {
        let bundledPath = "\(bundleMacOSPath)/ffprobe"
        if FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }
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
        
        for chunk in urls.chunks(of: maxConcurrency) {
            try await withThrowingTaskGroup(of: (Int, VideoItem).self) { group in
                for url in chunk {
                    let index = urls.firstIndex(of: url) ?? 0
                    group.addTask {
                        let item = try self.probeVideo(at: url)
                        return (index, item)
                    }
                }
                
                for try await result in group {
                    completed += 1
                    results.append(result)
                    
                    let localCompleted = completed
                    await MainActor.run {
                        progress(localCompleted, total)
                    }
                }
            }
        }
        
        results.sort { $0.index < $1.index }
        return results.map { $0.item }
    }

    // MARK: - 混剪

    func mergeVideos(
        items: [VideoItem],
        outputURL: URL,
        config: MergeConfig,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        guard !items.isEmpty else {
            throw FFmpegError.mergeFailed("没有可用的视频素材")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TurboMix_\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let listPath = tempDir.appendingPathComponent("inputs.txt").path

        var listContent = ""
        for item in items {
            let escapedPath = item.url.path.replacingOccurrences(of: "'", with: "'\\''")
            listContent += "file '\(escapedPath)'\n"
        }
        try listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

        var script = "#!/bin/bash\nset -e\n\n"
        script += "rm -f '\(listPath.replacingOccurrences(of: "'", with: "'\\''"))' << 'INPUTS_EOF'\n\(listContent)INPUTS_EOF\n\n"

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
        
        let scriptPath = tempDir.appendingPathComponent("merge.sh").path
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        let fullData = try stderrPipe.fileHandleForReading.readToEnd()
        let output = String(data: fullData ?? Data(), encoding: .utf8) ?? ""
        
        if let progressLine = output.components(separatedBy: .newlines).last {
            if let percent = extractProgress(from: progressLine) {
                await MainActor.run {
                    progress(percent.0, percent.1)
                }
            }
        }

        process.waitUntilExit()
        try? FileManager.default.removeItem(at: tempDir)

        guard process.terminationStatus == 0 else {
            throw FFmpegError.mergeFailed("ffmpeg 合并失败，退出码: \(process.terminationStatus)")
        }
    }

    private func extractProgress(from line: String) -> (Double, String)? {
        let components = line.components(separatedBy: "time=")
        guard components.count > 1 else { return nil }
        
        let timePart = components[1].components(separatedBy: " ").first ?? ""
        let timeComponents = timePart.components(separatedBy: ":")
        
        guard timeComponents.count >= 3 else { return nil }
        
        let hours = Int(timeComponents[0]) ?? 0
        let minutes = Int(timeComponents[1]) ?? 0
        let seconds = Double(timeComponents[2]) ?? 0.0
        
        let totalSeconds = Double(hours) * 3600.0 + Double(minutes) * 60.0 + seconds
        let percent = min(totalSeconds / 100.0, 100.0)
        
        return (percent, "合成中...")
    }

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

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

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
