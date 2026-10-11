import Foundation
import AVFoundation
import Accelerate

public struct VoiceFocusPreview: Sendable, Equatable {
    public var original: URL
    public var focused: URL
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(original: URL, focused: URL, start: TimeInterval, duration: TimeInterval) {
        self.original = original; self.focused = focused; self.start = start; self.duration = duration
    }
}

struct VoiceFocusBlock: Sendable {
    var start: TimeInterval
    var samples: [Float]
    var music: Bool
    var audible: Bool {
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return meanSquare >= 0.000_001 // -60 dBFS RMS; pauses can occur within a speech excerpt.
    }
}

enum VoiceFocusPCM {
    static func mono(_ buffer: AVAudioPCMBuffer, channels: UnsafePointer<UnsafeMutablePointer<Float>>) -> [Float] {
        let count = Int(buffer.frameLength)
        var result = Array(UnsafeBufferPointer(start: channels[0], count: count))
        if buffer.format.channelCount > 1 {
            for channel in 1..<Int(buffer.format.channelCount) {
                vDSP_vadd(result, 1, channels[channel], 1, &result, 1, vDSP_Length(count))
            }
            var scale = 1 / Float(buffer.format.channelCount)
            vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(count))
        }
        return result
    }

    static func read(_ file: AVAudioFile, start: TimeInterval, end: TimeInterval) throws -> [VoiceFocusBlock] {
        let rate = file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(max(512, Int(rate*0.4)))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
        file.framePosition = AVAudioFramePosition(start*rate)
        let lastFrame = min(file.length, AVAudioFramePosition(end*rate))
        var blocks: [VoiceFocusBlock] = []
        while file.framePosition < lastFrame {
            try Task.checkCancellation()
            let offset = Double(file.framePosition)/rate
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), lastFrame-file.framePosition)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let mono = mono(buffer, channels: channels)
            blocks.append(VoiceFocusBlock(start: offset, samples: mono, music: VoiceFocusRenderer.likelyMusic(mono, rate: rate)))
        }
        return blocks
    }

    // Use the same sustained, three-block detector as the full renderer.
    static func musicFlags(_ blocks: [VoiceFocusBlock]) -> [Bool] {
        var flags = [Bool](repeating: false, count: blocks.count), start = 0
        while start < blocks.count {
            guard blocks[start].music else { start += 1; continue }
            var end = start+1
            while end < blocks.count && blocks[end].music { end += 1 }
            if end-start >= 3 { for i in start..<end { flags[i] = true } }
            start = end
        }
        return flags
    }

    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        try Task.checkCancellation()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        // Lossless PCM avoids encoder delay and makes the A/B files exactly equal in length.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let count = min(8192, samples.count-offset)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!+offset, count: count) }
            try file.write(from: buffer); offset += count
        }
        try LocalFiles.protect(url)
    }
}

/// Bounded, stratified K-weighted gated estimate of the *whole trim*, never just the excerpt.
/// Cache source samples once; changing strength/music reuses them without rereading the recording.
actor VoiceFocusAnalysisCache {
    struct Key: Hashable {
        var checksum: String
        var trim: AudioTrimWindow
        var size: Int?
        var modified: Date?
    }
    struct Settings: Hashable { var strength: Double; var processMusic: Bool }
    struct Analysis: Sendable {
        var rate: Double
        var windows: [[VoiceFocusBlock]]
        var gains: [Settings: Double] = [:]
    }
    private var entries: [Key: Analysis] = [:]
    private var pending: [Key: (id: UUID, task: Task<Analysis, any Error>)] = [:]
    private(set) var estimationCount = 0

    func gain(source: URL, checksum: String?, trim: AudioTrimWindow, strength: Double, processMusic: Bool) async throws -> Double {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(checksum: try checksum ?? LocalFiles.checksum(source), trim: trim, size: values.fileSize, modified: values.contentModificationDate)
        let settings = Settings(strength: strength, processMusic: processMusic)
        var analysis: Analysis
        if let cached = entries[key] { analysis = cached }
        else {
            let work: (id: UUID, task: Task<Analysis, any Error>)
            if let existing = pending[key] { work = existing }
            else {
                work = (UUID(), Task { try await Self.estimate(source: source, trim: trim) })
                pending[key] = work
            }
            do { analysis = try await work.task.value }
            catch {
                if pending[key]?.id == work.id { pending[key] = nil }
                throw error
            }
            if entries[key] == nil {
                estimationCount += 1
                if entries.count >= 4 { entries.removeAll() } // Bound memory; no persisted audio/analysis cache.
                entries[key] = analysis
            }
            if pending[key]?.id == work.id { pending[key] = nil }
        }
        try Task.checkCancellation()
        if let gain = analysis.gains[settings] { return gain }
        let gain = try await Self.measure(analysis, settings: settings)
        try Task.checkCancellation()
        var updated = entries[key] ?? analysis
        updated.gains[settings] = gain; entries[key] = updated
        return gain
    }

    @concurrent private static func estimate(source: URL, trim: AudioTrimWindow) async throws -> Analysis {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        try trim.validate(duration: Double(file.length)/file.processingFormat.sampleRate)
        let duration = min(trim.end, Double(file.length)/file.processingFormat.sampleRate)-trim.start
        let windowDuration = min(1.2, duration)
        let count = min(12, max(1, Int(ceil(duration/windowDuration))))
        var windows: [[VoiceFocusBlock]] = []
        for i in 0..<count {
            try Task.checkCancellation()
            let start = trim.start + (count == 1 ? 0 : Double(i)/Double(count-1)*(duration-windowDuration))
            windows.append(try VoiceFocusPCM.read(file, start: start, end: start+windowDuration))
        }
        return Analysis(rate: file.processingFormat.sampleRate, windows: windows)
    }

    @concurrent private static func measure(_ analysis: Analysis, settings: Settings) async throws -> Double {
        var powers: [Double] = []
        for window in analysis.windows {
            var dsp = SpeechDSP(rate: analysis.rate, strength: settings.strength)
            var meter = LoudnessMeter(rate: analysis.rate)
            let music = VoiceFocusPCM.musicFlags(window)
            for (i, block) in window.enumerated() {
                try Task.checkCancellation()
                meter.add(dsp.process(block.samples, bypass: !settings.processMusic && music[i]))
            }
            powers += meter.blocks
            if meter.count > 0 { powers.append(meter.sum/Double(meter.count)) }
        }
        var integrated = LoudnessMeter(rate: analysis.rate); integrated.blocks = powers
        return max(-30, min(18, -16-(integrated.lufs ?? -16)))
    }
}

enum VoiceFocusExcerpt {
    static func window(trim: AudioTrimWindow, around time: TimeInterval?) throws -> AudioTrimWindow? {
        guard let time else { return nil }
        guard time.isFinite else { throw SermonSetError(title: "Invalid preview time", message: "Choose a playhead time within the recording.") }
        let duration = min(20, trim.duration)
        let start = max(trim.start, min(time, trim.end-duration))
        return AudioTrimWindow(start: start, end: start+duration)
    }

    static func select(file: AVAudioFile, trim: AudioTrimWindow) throws -> AudioTrimWindow {
        let rate = file.processingFormat.sampleRate, duration = min(20, trim.duration)
        // Short recordings still provide a preview; a 30-second lead-in cannot fit there.
        let start = trim.duration >= 50 ? trim.start+30 : trim.start
        let capacity = AVAudioFrameCount(max(512, Int(rate*0.4)))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
        file.framePosition = AVAudioFramePosition(start*rate)
        let endFrame = AVAudioFramePosition(trim.end*rate), needed = Int((duration*rate).rounded(.down))
        var queue: [VoiceFocusBlock] = [], frames = 0, musicRun = 0
        while file.framePosition < endFrame {
            try Task.checkCancellation()
            let offset = Double(file.framePosition)/rate
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), endFrame-file.framePosition)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let samples = VoiceFocusPCM.mono(buffer, channels: channels)
            let candidate = VoiceFocusRenderer.likelyMusic(samples, rate: rate)
            queue.append(VoiceFocusBlock(start: offset, samples: samples, music: false))
            musicRun = candidate ? musicRun+1 : 0
            if musicRun >= 3 { for i in max(0, queue.count-3)..<queue.count { queue[i].music = true } }
            frames += samples.count
            while queue.count > 1 && frames-queue[0].samples.count >= needed { frames -= queue.removeFirst().samples.count }
            if frames >= needed && musicRun == 0 && !queue.contains(where: \.music) && queue.filter(\.audible).count*4 >= queue.count*3 {
                return AudioTrimWindow(start: queue[0].start, end: min(trim.end, queue[0].start+duration))
            }
        }
        throw SermonSetError(title: "Speech preview unavailable", message: "No steady speech excerpt was found outside music or quiet sections. Choose a playhead time to preview that part of the recording.")
    }
}

extension VoiceFocusRenderer {
    @concurrent static func preview(source: URL, checksum: String?, requestedTrim: AudioTrimWindow, strength: Double, processMusic: Bool, around time: TimeInterval?, directory: URL, analysis: VoiceFocusAnalysisCache) async throws -> VoiceFocusPreview {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, decodedDuration = Double(file.length)/rate
        try requestedTrim.validate(duration: decodedDuration)
        let trim = AudioTrimWindow(start: requestedTrim.start, end: min(requestedTrim.end, decodedDuration))
        let excerpt = try VoiceFocusExcerpt.window(trim: trim, around: time) ?? VoiceFocusExcerpt.select(file: file, trim: trim)
        let gainDB = try await analysis.gain(source: source, checksum: checksum, trim: trim, strength: strength, processMusic: processMusic)
        // Align limiter/detector blocks to the full trim and warm the filters/envelope before the excerpt.
        let blockDuration = Double(max(512, Int(rate*0.4)))/rate
        let firstBlock = max(0, floor((excerpt.start-trim.start)/blockDuration)-3)
        let readStart = trim.start+firstBlock*blockDuration
        let readEnd = min(trim.end, trim.start+(ceil((excerpt.end-trim.start)/blockDuration)+3)*blockDuration)
        let blocks = try VoiceFocusPCM.read(file, start: readStart, end: readEnd), music = VoiceFocusPCM.musicFlags(blocks)
        var dsp = SpeechDSP(rate: rate, strength: strength)
        var original: [Float] = [], focused: [Float] = []
        let gain = pow(10, gainDB/20)
        for (i, block) in blocks.enumerated() {
            try Task.checkCancellation()
            let processed = dsp.process(block.samples, bypass: !processMusic && music[i])
            let limited = SpeechDSP.limited(processed, gain: gain)
            let lower = max(0, Int((excerpt.start*rate).rounded(.down))-Int((block.start*rate).rounded(.down)))
            let upper = min(block.samples.count, Int((excerpt.end*rate).rounded(.down))-Int((block.start*rate).rounded(.down)))
            if lower < upper { original += block.samples[lower..<upper]; focused += limited[lower..<upper] }
        }
        guard !focused.isEmpty else { throw SermonSetError(title: "Audio unavailable", message: "The selected excerpt contains no playable audio.") }
        var originalMeter = LoudnessMeter(rate: rate), focusedMeter = LoudnessMeter(rate: rate)
        originalMeter.add(original); focusedMeter.add(focused)
        let matchGain = pow(10, ((focusedMeter.lufs ?? -70)-(originalMeter.lufs ?? -70))/20)
        var scale = Float(matchGain)
        vDSP_vsmul(original, 1, &scale, &original, 1, vDSP_Length(original.count))
        let originalURL = directory.appendingPathComponent("original.caf"), focusedURL = directory.appendingPathComponent("focused.caf")
        try VoiceFocusPCM.write(original, rate: rate, to: originalURL)
        try VoiceFocusPCM.write(focused, rate: rate, to: focusedURL)
        try Task.checkCancellation()
        return VoiceFocusPreview(original: originalURL, focused: focusedURL, start: excerpt.start, duration: Double(focused.count)/rate)
    }
}

@MainActor extension SermonStore {
    var voiceFocusPreviewDirectory: URL {
        let caches = configuration == .live ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] : root.appendingPathComponent("Caches", isDirectory: true)
        return caches.appendingPathComponent("VoiceFocusPreview", isDirectory: true)
    }

    public func previewVoiceFocus(sermonID: UUID, strength: Double, processMusic: Bool, around time: TimeInterval?) async throws -> VoiceFocusPreview {
        voiceFocusPreviewTask?.cancel()
        voiceFocusPreviewTask = nil
        let request = UUID(); voiceFocusPreviewRequest = request
        try? FileManager.default.removeItem(at: voiceFocusPreviewDirectory)
        try Task.checkCancellation()
        guard strength.isFinite, (0...1).contains(strength), let source = audioAssets(for: sermonID).first(where: { [.original, .imported, .sample].contains($0.kind) }), let url = audioURL(for: source) else {
            throw SermonSetError(title: "Original unavailable", message: "Choose an original recording and strength from 0 to 100 percent.")
        }
        let trim = trimWindow(for: source.id) ?? AudioTrimWindow(start: 0, end: source.duration)
        let directory = voiceFocusPreviewDirectory.appendingPathComponent(request.uuidString, isDirectory: true)
        try LocalFiles.createDirectory(directory)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var protectedDirectory = directory; try protectedDirectory.setResourceValues(excluded)
        let task = Task {
            try await VoiceFocusRenderer.preview(source: url, checksum: source.checksumSHA256, requestedTrim: trim, strength: strength, processMusic: processMusic, around: time, directory: directory, analysis: voiceFocusAnalysis)
        }
        voiceFocusPreviewTask = task
        do {
            let preview = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard voiceFocusPreviewRequest == request else { throw CancellationError() }
            voiceFocusPreviewTask = nil
            return preview
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if voiceFocusPreviewRequest == request { voiceFocusPreviewTask = nil }
            // Do not publish preview failures into persistent or observable store state.
            if task.isCancelled || Task.isCancelled { throw CancellationError() }
            throw SermonStore.error(error)
        }
    }
}
