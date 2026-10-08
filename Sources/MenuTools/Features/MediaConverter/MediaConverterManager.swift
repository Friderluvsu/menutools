import AppKit
import Combine
import Foundation
import UserNotifications

enum MediaCategory: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    case gif = "GIF"
    case image = "Image"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .video: return "video.fill"
        case .audio: return "music.note"
        case .gif: return "sparkles"
        case .image: return "photo.fill"
        }
    }
}

enum VideoPreset: String, CaseIterable, Identifiable {
    case mp4H264 = "MP4 (H.264 Universal)"
    case mp4HEVC = "MP4 (HEVC / H.265 Small)"
    case movProRes = "MOV (Apple ProRes)"
    case webm = "WebM (VP9 Web)"
    case mkv = "MKV (Matroska)"
    case compressDiscord = "Compress for Discord (< 25MB)"
    case compressTelegram = "Compress for Telegram (< 50MB)"
    case compressStandard = "Compress (Balanced)"

    var id: String { rawValue }
    var extensionName: String {
        switch self {
        case .webm: return "webm"
        case .movProRes: return "mov"
        case .mkv: return "mkv"
        default: return "mp4"
        }
    }
}

enum AudioPreset: String, CaseIterable, Identifiable {
    case mp3High = "MP3 (320 kbps High)"
    case mp3Standard = "MP3 (192 kbps)"
    case m4aAAC = "M4A / AAC (256 kbps)"
    case wavLossless = "WAV (Lossless 16-bit)"
    case flacLossless = "FLAC (Lossless)"

    var id: String { rawValue }
    var extensionName: String {
        switch self {
        case .m4aAAC: return "m4a"
        case .wavLossless: return "wav"
        case .flacLossless: return "flac"
        default: return "mp3"
        }
    }
}

enum GIFQualityPreset: String, CaseIterable, Identifiable {
    case high640 = "High Quality (640px, 24 FPS)"
    case standard480 = "Standard (480px, 15 FPS)"
    case compact320 = "Compact (320px, 12 FPS)"
    case original = "Original Resolution (30 FPS)"

    var id: String { rawValue }
}

enum ImagePreset: String, CaseIterable, Identifiable {
    case webp = "WebP (Modern Web)"
    case png = "PNG (Lossless)"
    case jpgHigh = "JPG (High Quality 90%)"
    case jpgSmall = "JPG (Compressed 70%)"
    case heic = "HEIC (Apple High Efficiency)"

    var id: String { rawValue }
    var extensionName: String {
        switch self {
        case .webp: return "webp"
        case .png: return "png"
        case .heic: return "heic"
        default: return "jpg"
        }
    }
}

enum ConversionStatus: Equatable {
    case queued
    case converting(progress: Double, speed: String)
    case completed(outputURL: URL)
    case failed(error: String)
}

struct MediaTask: Identifiable {
    let id: UUID = UUID()
    let inputURL: URL
    let category: MediaCategory
    var outputFormat: String
    var status: ConversionStatus = .queued
    var fileSizeFormatted: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

@MainActor
final class MediaConverterManager: ObservableObject {
    @Published var tasks: [MediaTask] = []
    @Published var selectedCategory: MediaCategory = .video
    @Published var selectedVideoPreset: VideoPreset = .mp4H264
    @Published var selectedAudioPreset: AudioPreset = .mp3High
    @Published var selectedGIFPreset: GIFQualityPreset = .high640
    @Published var selectedImagePreset: ImagePreset = .webp
    @Published var outputDirectory: URL?
    @Published var isConverting: Bool = false
    @Published var ffmpegPath: String?

    init(requestNotifications: Bool = true) {
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin")?.path,
            FileManager.default.isExecutableFile(atPath: bundled)
        {
            self.ffmpegPath = bundled
        } else {
            self.ffmpegPath = Shell.which("ffmpeg")
        }
        self.outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if requestNotifications {
            requestNotificationPermission()
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let cat = detectCategory(url: url)
            let defaultFormat: String
            switch cat {
            case .video: defaultFormat = selectedVideoPreset.rawValue
            case .audio: defaultFormat = selectedAudioPreset.rawValue
            case .gif: defaultFormat = selectedGIFPreset.rawValue
            case .image: defaultFormat = selectedImagePreset.rawValue
            }

            let task = MediaTask(inputURL: url, category: cat, outputFormat: defaultFormat)
            tasks.append(task)
        }

        if !isConverting {
            startNextInQueue()
        }
    }

    private func detectCategory(url: URL) -> MediaCategory {
        let ext = url.pathExtension.lowercased()
        let videoExts = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv", "flv", "ts", "mts"]
        let audioExts = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "wma", "aiff"]
        let imageExts = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "gif", "bmp"]

        if selectedCategory == .gif && videoExts.contains(ext) {
            return .gif
        }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if imageExts.contains(ext) { return .image }
        return .video
    }

    func startNextInQueue() {
        guard let task = tasks.first(where: { $0.status == .queued }) else {
            isConverting = false
            return
        }

        isConverting = true
        convertTask(task: task)
    }

    private func convertTask(task: MediaTask) {
        let taskID = task.id
        guard let ffmpeg = ffmpegPath else {
            if let currentIndex = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[currentIndex].status = .failed(error: "Bundled FFmpeg runtime is unavailable")
            }
            startNextInQueue()
            return
        }
        let inputPath = task.inputURL.path
        let outDir = outputDirectory ?? task.inputURL.deletingLastPathComponent()
        let filenameBase = task.inputURL.deletingPathExtension().lastPathComponent

        let outputURL: URL
        // Arguments go straight to the process (no shell), so any file name is passed through literally.
        var executable = ffmpeg
        var arguments: [String] = []

        switch task.category {
        case .video:
            let preset = VideoPreset(rawValue: task.outputFormat) ?? .mp4H264
            let ext = preset.extensionName
            outputURL = outDir.appendingPathComponent("\(filenameBase)_converted.\(ext)")

            switch preset {
            case .mp4H264:
                arguments = ["-y", "-i", inputPath, "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-c:a", "aac", "-b:a", "192k", outputURL.path]
            case .mp4HEVC:
                arguments = ["-y", "-i", inputPath, "-c:v", "libx265", "-crf", "26", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", outputURL.path]
            case .movProRes:
                arguments = ["-y", "-i", inputPath, "-c:v", "prores_ks", "-profile:v", "3", "-c:a", "pcm_s16le", outputURL.path]
            case .webm:
                arguments = ["-y", "-i", inputPath, "-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-c:a", "libopus", outputURL.path]
            case .mkv:
                arguments = ["-y", "-i", inputPath, "-c", "copy", outputURL.path]
            case .compressDiscord:
                arguments = ["-y", "-i", inputPath, "-c:v", "libx264", "-crf", "30", "-preset", "fast", "-fs", "24M", "-c:a", "aac", "-b:a", "128k", outputURL.path]
            case .compressTelegram:
                arguments = ["-y", "-i", inputPath, "-c:v", "libx264", "-crf", "28", "-preset", "fast", "-fs", "48M", "-c:a", "aac", "-b:a", "128k", outputURL.path]
            case .compressStandard:
                arguments = ["-y", "-i", inputPath, "-c:v", "libx264", "-crf", "27", "-preset", "slow", "-c:a", "aac", "-b:a", "128k", outputURL.path]
            }

        case .audio:
            let preset = AudioPreset(rawValue: task.outputFormat) ?? .mp3High
            let ext = preset.extensionName
            outputURL = outDir.appendingPathComponent("\(filenameBase)_audio.\(ext)")

            switch preset {
            case .mp3High:
                arguments = ["-y", "-i", inputPath, "-vn", "-c:a", "libmp3lame", "-b:a", "320k", outputURL.path]
            case .mp3Standard:
                arguments = ["-y", "-i", inputPath, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", outputURL.path]
            case .m4aAAC:
                arguments = ["-y", "-i", inputPath, "-vn", "-c:a", "aac", "-b:a", "256k", outputURL.path]
            case .wavLossless:
                arguments = ["-y", "-i", inputPath, "-vn", "-c:a", "pcm_s16le", outputURL.path]
            case .flacLossless:
                arguments = ["-y", "-i", inputPath, "-vn", "-c:a", "flac", outputURL.path]
            }

        case .gif:
            let preset = GIFQualityPreset(rawValue: task.outputFormat) ?? .high640
            outputURL = outDir.appendingPathComponent("\(filenameBase).gif")

            var scale = "scale=640:-1:flags=lanczos"
            var fps = "fps=24"
            if preset == .standard480 {
                scale = "scale=480:-1:flags=lanczos"
                fps = "fps=15"
            } else if preset == .compact320 {
                scale = "scale=320:-1:flags=lanczos"
                fps = "fps=12"
            } else if preset == .original {
                scale = "scale=iw:-1:flags=lanczos"
                fps = "fps=30"
            }

            arguments = ["-y", "-i", inputPath, "-vf", "\(fps),\(scale),split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-loop", "0", outputURL.path]

        case .image:
            let preset = ImagePreset(rawValue: task.outputFormat) ?? .webp
            let ext = preset.extensionName
            outputURL = outDir.appendingPathComponent("\(filenameBase)_converted.\(ext)")

            switch preset {
            case .webp:
                arguments = ["-y", "-i", inputPath, "-c:v", "libwebp", "-quality", "85", outputURL.path]
            case .png:
                executable = "/usr/bin/sips"
                arguments = ["-s", "format", "png", inputPath, "--out", outputURL.path]
            case .jpgHigh:
                executable = "/usr/bin/sips"
                arguments = ["-s", "format", "jpeg", "-s", "formatOptions", "90", inputPath, "--out", outputURL.path]
            case .jpgSmall:
                executable = "/usr/bin/sips"
                arguments = ["-s", "format", "jpeg", "-s", "formatOptions", "70", inputPath, "--out", outputURL.path]
            case .heic:
                executable = "/usr/bin/sips"
                arguments = ["-s", "format", "heic", inputPath, "--out", outputURL.path]
            }
        }

        guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            startNextInQueue()
            return
        }
        self.tasks[currentIndex].status = .converting(progress: 0.2, speed: "Converting...")

        Task.detached { [weak self] in
            let exitCode = Shell.run(executable: executable, arguments: arguments)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let currentIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                    if exitCode == 0 && FileManager.default.fileExists(atPath: outputURL.path) {
                        self.tasks[currentIndex].status = .completed(outputURL: outputURL)
                        self.sendNativeNotification(title: "Conversion Completed", body: outputURL.lastPathComponent)
                    } else {
                        self.tasks[currentIndex].status = .failed(error: "Conversion failed (Code \(exitCode))")
                    }
                }
                self.startNextInQueue()
            }
        }
    }

    func clearAll() {
        if isConverting {
            tasks.removeAll {
                if case .converting = $0.status { return false }
                return true
            }
        } else {
            tasks.removeAll()
        }
    }

    func clearCompleted() {
        tasks.removeAll {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    func removeTask(id: UUID) {
        tasks.removeAll {
            guard $0.id == id else { return false }
            if case .converting = $0.status { return false }
            return true
        }
    }

    private func sendNativeNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
