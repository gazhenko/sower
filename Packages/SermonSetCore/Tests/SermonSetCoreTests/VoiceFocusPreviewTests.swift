import Testing
import Foundation
import AVFoundation
@testable import SermonSetCore

@Suite(.serialized) @MainActor struct VoiceFocusPreviewTests {
    private func directory() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("build/section17/fixtures/\(UUID())", isDirectory: true)
        try LocalFiles.createDirectory(directory)
        return directory
    }

    private func fixture(_ directory: URL, seconds: Int = 90, rate: Double = 16_000, signal: (Double) -> Int = { _ in 2 }) throws -> URL {
        let url = directory.appendingPathComponent("source.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        var random: UInt64 = 42
        var smoothed: Float = 0
        for second in 0..<seconds {
            for i in 0..<Int(rate) {
                let time = Double(second)+Double(i)/rate
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(Double(random >> 32)/Double(UInt32.max)*2-1)
                smoothed = smoothed*0.5+noise*0.5
                switch signal(time) {
                case 0: buffer.floatChannelData![0][i] = 0
                case 1: buffer.floatChannelData![0][i] = Float(0.12*sin(2*Double.pi*80*time))
                case 3: buffer.floatChannelData![0][i] = smoothed*0.12
                case 4, 5:
                    let low = 0.05*sin(2*Double.pi*230*time)
                    let mid = 0.04*sin(2*Double.pi*521*time)
                    let high = 0.03*sin(2*Double.pi*1139*time)
                    buffer.floatChannelData![0][i] = Float((low+mid+high)*(signal(time) == 5 ? 0.08 : 1))
                default: buffer.floatChannelData![0][i] = smoothed*0.01
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func loudness(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var meter = LoudnessMeter(rate: file.processingFormat.sampleRate)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            meter.add(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        }
        return try #require(meter.lufs)
    }

    @Test func playheadAndTrimClamping() throws {
        let trim = AudioTrimWindow(start: 10, end: 80)
        #expect(try VoiceFocusExcerpt.window(trim: trim, around: 37) == AudioTrimWindow(start: 37, end: 57))
        #expect(try VoiceFocusExcerpt.window(trim: trim, around: -20) == AudioTrimWindow(start: 10, end: 30))
        #expect(try VoiceFocusExcerpt.window(trim: trim, around: 100) == AudioTrimWindow(start: 60, end: 80))
        #expect(try VoiceFocusExcerpt.window(trim: AudioTrimWindow(start: 5, end: 12), around: 10) == AudioTrimWindow(start: 5, end: 12))
        #expect(try VoiceFocusExcerpt.window(trim: trim, around: nil) == nil)
        #expect(throws: SermonSetError.self) { try VoiceFocusExcerpt.window(trim: trim, around: .nan) }
    }

    @Test func automaticExcerptSkipsMusicAndNearSilence() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root) { time in time < 50 ? 1 : (time < 55 ? 0 : 2) }
        let file = try AVAudioFile(forReading: source)
        let window = try VoiceFocusExcerpt.select(file: file, trim: AudioTrimWindow(start: 10, end: 90))
        #expect(window.start >= 50 && window.start <= 55)
        #expect(abs(window.duration-20) < 0.0001)
        let blocks = try VoiceFocusPCM.read(file, start: window.start, end: window.end)
        #expect(!VoiceFocusPCM.musicFlags(blocks).contains(true))
        let silent = try fixture(root, seconds: 60) { _ in 0 }
        #expect(throws: SermonSetError.self) { try VoiceFocusExcerpt.select(file: AVAudioFile(forReading: silent), trim: AudioTrimWindow(start: 0, end: 60)) }
    }

    @Test func matchedPairUsesWholeTrimGainAndLeavesStoreUntouched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, rate: 48_000) { time in time < 30 ? 5 : 4 }
        let store = SermonStore(configuration: .uiTest(directory: root.appendingPathComponent("library")))
        let sermon = try await store.importAudio(from: source, title: "Preview fixture")
        let original = try #require(store.audioAssets(for: sermon.id).first), originalURL = try #require(store.audioURL(for: original))
        try store.setTrimWindow(AudioTrimWindow(start: 2, end: 88), for: original.id)
        let document = try LocalFiles.encoder.encode(store.document), bytes = try Data(contentsOf: store.storeURL)
        let paths = try FileManager.default.contentsOfDirectory(atPath: store.recordingsDirectory.path)
        let hash = try LocalFiles.checksum(originalURL)
        await #expect(throws: SermonSetError.self) { try await store.previewVoiceFocus(sermonID: sermon.id, strength: .nan, processMusic: false, around: 5) }
        await #expect(throws: SermonSetError.self) { try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: false, around: .nan) }
        let preview = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: false, around: 5)
        #expect(preview.start == 5 && abs(preview.duration-20) < 0.0001)
        #expect(abs(try loudness(preview.original)-loudness(preview.focused)) < 0.05)
        #expect(abs(try AudioFiles.probe(preview.original).duration-AudioFiles.probe(preview.focused).duration) < 0.0001)
        #expect(try LocalFiles.encoder.encode(store.document) == document)
        #expect(try Data(contentsOf: store.storeURL) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.recordingsDirectory.path) == paths)
        #expect(try LocalFiles.checksum(originalURL) == hash)
        #expect(store.audioAssets(for: sermon.id) == [original] && store.lastError == nil)
        let gain = try await store.voiceFocusAnalysis.gain(source: originalURL, checksum: original.checksumSHA256, trim: AudioTrimWindow(start: 2, end: 88), strength: 0.7, processMusic: false)
        let localGain = try await VoiceFocusAnalysisCache().gain(source: originalURL, checksum: original.checksumSHA256, trim: AudioTrimWindow(start: 5, end: 25), strength: 0.7, processMusic: false)
        #expect(abs(gain-localGain) > 5) // Normalizing only the quiet excerpt would give a misleading preview.
        let enhanced = try await store.renderVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: false)
        #expect(store.derivativeProvenance(for: enhanced.id)?.diagnostics.appliedGainDB == gain)
        #expect(await store.voiceFocusAnalysis.estimationCount == 1)
        // The excerpt's PCM level/tone also matches the corresponding full-copy AAC audio.
        let focusedURL = try #require(store.audioURL(for: enhanced))
        let full = try AVAudioFile(forReading: focusedURL)
        let blocks = try VoiceFocusPCM.read(full, start: 3, end: 23) // full copy starts at original time 2
        var meter = LoudnessMeter(rate: full.processingFormat.sampleRate)
        for block in blocks { meter.add(block.samples) }
        let previewLUFS = try loudness(preview.focused), fullLUFS = try #require(meter.lufs)
        #expect(abs(previewLUFS-fullLUFS) < 0.25)
    }

    @Test func nextPreviewAndStoreInitializationCleanTemporaryPair() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, seconds: 24)
        let store = SermonStore(configuration: .uiTest(directory: root.appendingPathComponent("library")))
        let sermon = try await store.importAudio(from: source, title: "Cleanup")
        let first = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0, processMusic: false, around: 0)
        #expect(FileManager.default.fileExists(atPath: first.original.path) && FileManager.default.fileExists(atPath: first.focused.path))
        let second = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 1, processMusic: true, around: 1)
        #expect(!FileManager.default.fileExists(atPath: first.original.path) && !FileManager.default.fileExists(atPath: first.focused.path))
        #expect(FileManager.default.fileExists(atPath: second.original.path))
        #expect(await store.voiceFocusAnalysis.estimationCount == 1) // Settings reuse the source/trim sample cache.
        _ = SermonStore(configuration: .uiTest(directory: store.root))
        #expect(!FileManager.default.fileExists(atPath: second.original.path) && !FileManager.default.fileExists(atPath: second.focused.path))
    }

    @Test func newerRequestAndCallerCancellationDiscardOldResults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, seconds: 60)
        let store = SermonStore(configuration: .uiTest(directory: root.appendingPathComponent("library")))
        let sermon = try await store.importAudio(from: source, title: "Cancellation")
        let bytes = try Data(contentsOf: store.storeURL)
        let first = Task { try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.4, processMusic: false, around: 0) }
        while store.voiceFocusPreviewTask == nil { await Task.yield() }
        let second = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.6, processMusic: true, around: 20)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(FileManager.default.fileExists(atPath: second.original.path) && FileManager.default.fileExists(atPath: second.focused.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.voiceFocusPreviewDirectory.path).count == 1)
        let cancelled = Task { try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.2, processMusic: false, around: 0) }
        while store.voiceFocusPreviewTask == nil { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.voiceFocusPreviewDirectory.path).isEmpty)
        #expect(try Data(contentsOf: store.storeURL) == bytes && store.lastError == nil)
    }

    @Test func trimAndSourceChangesInvalidateAnalysis() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, seconds: 30)
        let cache = VoiceFocusAnalysisCache(), hash = try LocalFiles.checksum(source)
        _ = try await cache.gain(source: source, checksum: hash, trim: AudioTrimWindow(start: 0, end: 30), strength: 0.5, processMusic: false)
        _ = try await cache.gain(source: source, checksum: hash, trim: AudioTrimWindow(start: 2, end: 30), strength: 0.5, processMusic: false)
        #expect(await cache.estimationCount == 2)
        _ = try fixture(root, seconds: 30) { _ in 3 }
        _ = try await cache.gain(source: source, checksum: LocalFiles.checksum(source), trim: AudioTrimWindow(start: 2, end: 30), strength: 0.5, processMusic: false)
        #expect(await cache.estimationCount == 3)
    }

    @Test func acceleratedProcessingMatchesScalarChain() throws {
        let samples: [Float] = (0..<19_200).map { i in
            let low = 0.13*sin(Double(i)*0.067)
            let high = 0.08*cos(Double(i)*0.13)
            return Float(low+high)
        }
        var scalar = SpeechDSP(rate: 48_000, strength: 0.8), vector = scalar
        let reference = samples.map { scalar.process($0, bypass: false) }
        let output = vector.process(samples, bypass: false)
        #expect(zip(reference, output).allSatisfy { abs($0-$1) < 0.000_001 })
        var scalarMeter = LoudnessMeter(rate: 48_000), vectorMeter = scalarMeter
        reference.forEach { scalarMeter.add($0) }; vectorMeter.add(output)
        #expect(abs(try #require(scalarMeter.lufs)-#require(vectorMeter.lufs)) < 0.000_001)
        // Verify filter state is carried into the next buffer, including a music bypass.
        let nextReference = samples.map { scalar.process($0, bypass: true) }
        #expect(vector.process(samples, bypass: true) == nextReference)
        let lastReference = samples.map { scalar.process($0, bypass: false) }
        #expect(zip(lastReference, vector.process(samples, bypass: false)).allSatisfy { abs($0-$1) < 0.000_001 })
        let limited = SpeechDSP.limited(samples, gain: 12)
        let scaled = samples.map { Double($0)*12 }
        var peak = scaled.map(abs).max() ?? 0
        for i in 1..<(scaled.count-2) {
            let a = scaled[i-1], b = scaled[i], c = scaled[i+1], d = scaled[i+2]
            for t in [0.25, 0.5, 0.75] {
                let y = b + 0.5*t*(c-a+t*(2*a-5*b+4*c-d+t*(3*(b-c)+d-a)))
                peak = max(peak, abs(y))
            }
        }
        let reduction = peak > 0.89 ? 0.89/peak : 1
        #expect(zip(scaled, limited).allSatisfy { abs(Float($0*reduction)-$1) < 0.000_001 })
    }

    @Test func realSamplePreviewLatency() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SermonStore(configuration: .uiTest(directory: root))
        let sermon = try #require(store.discoverCatalog.first)
        let clock = ContinuousClock(), coldStart = clock.now
        _ = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.5, processMusic: false, around: 35)
        let cold = coldStart.duration(to: clock.now), warmStart = clock.now
        _ = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: true, around: 40)
        let warm = warmStart.duration(to: clock.now), cachedStart = clock.now
        _ = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: true, around: 50)
        let cached = cachedStart.duration(to: clock.now)
        let automaticStart = clock.now
        let automatic = try await store.previewVoiceFocus(sermonID: sermon.id, strength: 0.7, processMusic: true, around: nil)
        let automaticTime = automaticStart.duration(to: clock.now)
        #expect(automatic.start >= 30 && abs(automatic.duration-20) < 0.0001)
        print("Voice Focus 20-second preview (real 48 kHz AAC fixture): cold=\(cold), cached-source/new-settings=\(warm), cached-gain=\(cached), automatic/cached-gain=\(automaticTime)")
        #expect(await store.voiceFocusAnalysis.estimationCount == 1)
    }
}
