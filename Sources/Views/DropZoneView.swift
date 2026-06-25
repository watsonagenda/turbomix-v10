//  DropZoneView.swift — TurboMix v8
//
//  辅助函数（拖放文件收集、视频 UT 类型）

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 文件收集

func collectVideoFiles(from urls: [URL]) -> [URL] {
    var result: [URL] = []
    for url in urls {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if SupportedFormats.isVideoFile(fileURL) { result.append(fileURL) }
            }
        } else if SupportedFormats.isVideoFile(url) { result.append(url) }
    }
    return result
}

// MARK: - 视频 UT 类型

func videoUTTypes() -> [UTType] {
    ["mp4", "mov", "m4v", "avi", "mkv", "mts", "ts", "webm", "flv", "wmv", "3gp"]
        .compactMap { UTType(filenameExtension: $0) }
}
