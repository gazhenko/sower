import Foundation
import AVFoundation
import Observation
import Accelerate

public enum AudioAlignment: Codable, Hashable, Sendable { case original, offset(seconds: Double), unavailable }

public struct AudioTrimWindow: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var duration: TimeInterval { end - start }
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
    public func validate(duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite, start >= 0, start < duration, end > start, end <= duration + 0.1 else {
            throw SermonSetError(title: "Trim needs review", message: "Choose start and end times within the original recording.")
        }
    }
}
public struct MusicSection: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
}
public struct VoiceFocusDiagnostics: Codable, Hashable, Sendable {
    public var clippingPercent: Double
    public var dropoutSeconds: Double
    public var appliedGainDB: Double
    public var inputLUFS: Double?
    public var outputLUFS: Double?
    public var peakDBFS: Double
    public var musicSections: [MusicSection]
}
public struct AudioDerivativeProvenance: Codable, Hashable, Sendable {
    public var sourceAssetID: UUID
    public var sourceChecksum: String
    public var trim: AudioTrimWindow
    public var strength: Double
    public var processMusic: Bool
    public var algorithm: String
    public var diagnostics: VoiceFocusDiagnostics
    /// Absent on older derivatives, which were made manually.
    public var madeAutomatically: Bool? = nil
}
struct CoreFeatures: Codable, Sendable {
    var officialSources: [UUID:OfficialSourceAuthorization]?
    var blockedAccountIDs: [String]?
    var serviceTokens: [UUID:String]?
    var publications: [UUID:PublicationJob]?
    var communityEditions: [UUID: CardEdition]?
    var community: CommunityCache?
    var serverKeys: [ServerSigningKey]?
    var trims: [UUID: AudioTrimWindow] = [:]
    var derivatives: [UUID: AudioDerivativeProvenance] = [:]
    var preferredListeningAssets: [UUID: UUID]?
    var locales: [UUID: String] = [:]
    var staleTakeaways: Set<UUID> = []
    var staleOutline: Set<UUID> = []
}

// RBJ biquads, constant-memory streaming; no alteration of source samples/files.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func sample(_ x: Double) -> Double {
        let y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y.isFinite ? y : 0
    }
    mutating func process(_ input: [Double]) -> [Double] {
        guard !input.isEmpty else { return [] }
        let coefficients = [b0, b1, b2, a1, a2]
        guard let setup = vDSP_biquad_CreateSetupD(coefficients, 1) else { return input.map { sample($0) } }
        defer { vDSP_biquad_DestroySetupD(setup) }
        var delay = [x2, x1, y2, y1]
        var output = [Double](repeating: 0, count: input.count)
        vDSP_biquadD(setup, &delay, input, 1, &output, 1, vDSP_Length(input.count))
        x2 = delay[0]; x1 = delay[1]; y2 = delay[2]; y1 = delay[3]
        return output
    }
    static func highPass(rate: Double, hz: Double) -> Self {
        let w = 2 * Double.pi * hz / rate, c = cos(w), alpha = sin(w) / sqrt(2), d = 1 + alpha
        return Self(b0: (1+c)/2/d, b1: -(1+c)/d, b2: (1+c)/2/d, a1: -2*c/d, a2: (1-alpha)/d)
    }
    static func shelf(rate: Double, hz: Double, db: Double) -> Self {
        let a = pow(10, db/40), w = 2 * Double.pi * hz/rate, c = cos(w), s = sin(w), q = s/sqrt(2), t = 2*sqrt(a)*q
        let d = (a+1)-(a-1)*c+t
        return Self(b0: a*((a+1)+(a-1)*c+t)/d, b1: -2*a*((a-1)+(a+1)*c)/d, b2: a*((a+1)+(a-1)*c-t)/d, a1: 2*((a-1)-(a+1)*c)/d, a2: ((a+1)-(a-1)*c-t)/d)
    }
}
struct SpeechDSP {
    var highPass: Biquad
    var presence: Biquad
    var envelope = 0.0
    let strength: Double
    let release: Double
    init(rate: Double, strength: Double) {
        self.strength = strength
        highPass = .highPass(rate: rate, hz: 80)
        presence = .shelf(rate: rate, hz: 2200, db: 2.5 * strength)
        release = exp(-1 / (rate * 0.08))
    }
    mutating func process(_ input: Float, bypass: Bool) -> Float {
        let x = input.isFinite ? Double(input) : 0
        let filtered = presence.sample(highPass.sample(x))
        envelope = max(abs(filtered), envelope * release)
        let db = 20 * log10(max(envelope, 1e-9))
        let gate = db < -48 ? pow(10, (db+48) * 0.4 * strength/20) : 1
        let compression = db > -18 ? pow(10, -(db+18) * 0.45 * strength/20) : 1
        if bypass || strength == 0 { return Float(x) }
        let wet = filtered * gate * compression
        return Float(x * (1-strength) + wet * strength)
    }
    mutating func process(_ input: [Float], bypass: Bool) -> [Float] {
        var values = [Double](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { destination in
                for i in source.indices { destination[i] = source[i].isFinite ? Double(source[i]) : 0 }
            }
        }
        let filtered = presence.process(highPass.process(values))
        guard !input.isEmpty else { return [] }
        var bases = [Double](repeating: 1, count: input.count), exponents = bases
        let gateThreshold = pow(10.0, -48.0/20), compressionThreshold = pow(10.0, -18.0/20)
        filtered.withUnsafeBufferPointer { wet in
            bases.withUnsafeMutableBufferPointer { base in
                exponents.withUnsafeMutableBufferPointer { exponent in
                    for i in wet.indices {
                        envelope = max(abs(wet[i]), envelope * release)
                        if envelope < gateThreshold { base[i] = max(envelope, 1e-9)/gateThreshold; exponent[i] = 0.4*strength }
                        else if envelope > compressionThreshold { base[i] = envelope/compressionThreshold; exponent[i] = -0.45*strength }
                    }
                }
            }
        }
        if bypass || strength == 0 { return values.map { Float($0) } }
        var gains = [Double](repeating: 0, count: input.count), count = Int32(input.count)
        vvpow(&gains, exponents, bases, &count)
        vDSP_vmulD(filtered, 1, gains, 1, &gains, 1, vDSP_Length(input.count))
        var dry = 1-strength, wet = strength
        vDSP_vsmulD(values, 1, &dry, &values, 1, vDSP_Length(input.count))
        vDSP_vsmaD(gains, 1, &wet, values, 1, &values, 1, vDSP_Length(input.count))
        var output = [Float](repeating: 0, count: input.count)
        vDSP_vdpsp(values, 1, &output, 1, vDSP_Length(input.count))
        return output
    }
    static func limited(_ samples: [Float], gain: Double) -> [Float] {
        // A conservative ceiling plus four-times cubic-interpolated intersample peak bounds.
        var scaled = [Double](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { source in
            scaled.withUnsafeMutableBufferPointer { destination in
                for i in source.indices { destination[i] = Double(source[i].isFinite ? source[i] : 0) * gain }
            }
        }
        guard !scaled.isEmpty else { return [] }
        var peak = 0.0
        vDSP_maxmgvD(scaled, 1, &peak, vDSP_Length(scaled.count))
        if scaled.count > 3 {
            scaled.withUnsafeBufferPointer { values in
                let n = vDSP_Length(scaled.count-3), base = values.baseAddress!
                var interpolated = [Double](repeating: 0, count: Int(n))
                for t in [0.25, 0.5, 0.75] {
                    var a = -0.5*t+t*t-0.5*t*t*t
                    var b = 1-2.5*t*t+1.5*t*t*t
                    var c = 0.5*t+2*t*t-1.5*t*t*t
                    var d = -0.5*t*t+0.5*t*t*t
                    vDSP_vsmulD(base, 1, &a, &interpolated, 1, n)
                    vDSP_vsmaD(base+1, 1, &b, interpolated, 1, &interpolated, 1, n)
                    vDSP_vsmaD(base+2, 1, &c, interpolated, 1, &interpolated, 1, n)
                    vDSP_vsmaD(base+3, 1, &d, interpolated, 1, &interpolated, 1, n)
                    var candidate = 0.0
                    vDSP_maxmgvD(interpolated, 1, &candidate, n)
                    peak = max(peak, candidate)
                }
            }
        }
        var reduction = peak > 0.89 ? 0.89/peak : 1
        vDSP_vsmulD(scaled, 1, &reduction, &scaled, 1, vDSP_Length(scaled.count))
        var lower = -0.89, upper = 0.89
        vDSP_vclipD(scaled, 1, &lower, &upper, &scaled, 1, vDSP_Length(scaled.count))
        var output = [Float](repeating: 0, count: samples.count)
        vDSP_vdpsp(scaled, 1, &output, 1, vDSP_Length(scaled.count))
        return output
    }
}
struct LoudnessMeter {
    var hp: Biquad, shelf: Biquad
    var sum = 0.0, count = 0
    var blocks: [Double] = []
    let blockFrames: Int
    init(rate: Double) {
        hp = .highPass(rate: rate, hz: 38)
        shelf = .shelf(rate: rate, hz: 1500, db: 4)
        blockFrames = max(1, Int(rate * 0.4))
    }
    mutating func add(_ sample: Float) {
        let y = hp.sample(shelf.sample(Double(sample)))
        sum += y*y; count += 1
        if count == blockFrames { blocks.append(sum/Double(count)); sum = 0; count = 0 }
    }
    mutating func add(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var values = [Double](repeating: 0, count: samples.count)
        vDSP_vspdp(samples, 1, &values, 1, vDSP_Length(samples.count))
        let filtered = hp.process(shelf.process(values))
        filtered.withUnsafeBufferPointer { values in
            var offset = 0
            while offset < values.count {
                let frames = min(blockFrames-count, values.count-offset)
                var energy = 0.0
                vDSP_svesqD(values.baseAddress!+offset, 1, &energy, vDSP_Length(frames))
                sum += energy; count += frames; offset += frames
                if count == blockFrames { blocks.append(sum/Double(count)); sum = 0; count = 0 }
            }
        }
    }
    var lufs: Double? {
        let all = blocks + (count > 0 ? [sum/Double(count)] : [])
        let absolute = all.filter { -0.691 + 10*log10(max($0, 1e-15)) > -70 }
        guard !absolute.isEmpty else { return nil }
        let average = absolute.reduce(0,+)/Double(absolute.count)
        let gated = absolute.filter { $0 > average * 0.1 }
        return -0.691 + 10*log10(gated.reduce(0,+)/Double(max(1,gated.count)))
    }
}
enum VoiceFocusRenderer {
    // Spectral flatness + sustained harmonic energy: deliberately a suggestion, not a rights verdict.
    static func likelyMusic(_ samples: [Float], rate: Double) -> Bool {
        guard samples.count >= 512 else { return false }
        let n = 512, stride = max(1, samples.count/n)
        let window = (0..<n).map { i in
            Double(samples[min(samples.count-1,i*stride)]) * (0.5-0.5*cos(2*Double.pi*Double(i)/Double(n-1)))
        }
        var energies: [Double] = []
        if let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), .FORWARD) {
            defer { vDSP_DFT_DestroySetupD(setup) }
            let imaginary = [Double](repeating: 0, count: n)
            var real = imaginary, imag = imaginary
            vDSP_DFT_ExecuteD(setup, window, imaginary, &real, &imag)
            energies = (2..<64).map { i in
                let power = real[i]*real[i] + imag[i]*imag[i]
                return max(1e-12, power)
            }
        } else {
            for bin in 2..<64 {
                let coefficient = 2*cos(2*Double.pi*Double(bin)/Double(n))
                var a = 0.0, b = 0.0
                for x in window { let next = x + coefficient*a-b; b = a; a = next }
                energies.append(max(1e-12,a*a+b*b-coefficient*a*b))
            }
        }
        let total = energies.reduce(0,+), mean = total/Double(energies.count)
        let flatness = exp(energies.map(log).reduce(0,+)/Double(energies.count))/mean
        let tonal = energies.sorted(by: >).prefix(3).reduce(0,+)/total
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let rms = sqrt(Double(meanSquare))
        return rms > 0.015 && (flatness > 0.65 || tonal > 0.65)
    }
    @concurrent static func render(source: URL, destination: URL, trim: AudioTrimWindow, strength: Double, processMusic: Bool, gainDB: Double? = nil) async throws -> (AudioFileInfo, VoiceFocusDiagnostics) {
        let sourceHash = try LocalFiles.checksum(source)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = input.processingFormat.sampleRate
        try trim.validate(duration: Double(input.length)/rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let effectiveEnd = min(trim.end, Double(input.length)/rate)
        let frames = AVAudioFramePosition((effectiveEnd-trim.start)*rate), start = AVAudioFramePosition(trim.start*rate)
        let intermediate = destination.deletingLastPathComponent().appendingPathComponent("\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        var music: [MusicSection] = [], previous = false, runStart = 0.0, runCount = 0
        var clipped = 0, silentFrames = 0, totalFrames = 0
        let capacity = AVAudioFrameCount(max(512, Int(rate*0.4)))
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity)!
        input.framePosition = start
        while input.framePosition < start+frames {
            try Task.checkCancellation()
            let offset = Double(input.framePosition-start)/rate
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity),start+frames-input.framePosition)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let mono = VoiceFocusPCM.mono(buffer, channels: channels)
            clipped += mono.filter { abs($0) >= 0.999 }.count
            let silent = mono.allSatisfy { abs($0) < 0.00001 }
            if silent { silentFrames += mono.count }
            totalFrames += mono.count
            let candidate = likelyMusic(mono, rate: rate)
            if candidate {
                if !previous { runStart = offset; runCount = 0 }
                runCount += 1
            } else if previous && runCount >= 3 { music.append(MusicSection(start: runStart+trim.start, end: offset+trim.start)) }
            previous = candidate
        }
        if previous && runCount >= 3 { music.append(MusicSection(start: runStart+trim.start, end: trim.end)) }
        input.framePosition = start
        var output: AVAudioFile? = try AVAudioFile(forWriting: intermediate, settings: format.settings)
        var dsp = SpeechDSP(rate: rate, strength: strength), meter = LoudnessMeter(rate: rate), originalMeter = LoudnessMeter(rate: rate)
        let processed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        while input.framePosition < start+frames {
            try Task.checkCancellation()
            let offset = Double(input.framePosition)/rate
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity),start+frames-input.framePosition)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            processed.frameLength = buffer.frameLength
            let mono = VoiceFocusPCM.mono(buffer, channels: channels)
            let bypass = !processMusic && music.contains { offset >= $0.start && offset < $0.end }
            let values = dsp.process(mono, bypass: bypass)
            values.withUnsafeBufferPointer { processed.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            meter.add(values); originalMeter.add(mono)
            try output!.write(from: processed)
        }
        output = nil
        let inputLUFS = originalMeter.lufs, preLUFS = meter.lufs
        let gainDB = gainDB ?? max(-30,min(18,-16-(preLUFS ?? -16))), gain = pow(10,gainDB/20)
        let pcm = try AVAudioFile(forReading: intermediate)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcm.processingFormat, frameCapacity: capacity)!
        var settings = AudioFiles.aacSettings; settings[AVSampleRateKey] = rate
        var final: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var finalMeter = LoudnessMeter(rate: rate), peak = 0.0
        while pcm.framePosition < pcm.length {
            try Task.checkCancellation(); try pcm.read(into: pcmBuffer)
            let values = SpeechDSP.limited(Array(UnsafeBufferPointer(start: pcmBuffer.floatChannelData![0], count: Int(pcmBuffer.frameLength))), gain: gain)
            values.withUnsafeBufferPointer { pcmBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            finalMeter.add(values)
            peak = max(peak, Double(values.map(abs).max() ?? 0))
            try final!.write(from: pcmBuffer)
        }
        final = nil; try LocalFiles.protect(destination)
        guard try LocalFiles.checksum(source) == sourceHash else { throw SermonSetError(title: "Original changed", message: "The source audio changed while processing. Retry with the original recording.") }
        return (try AudioFiles.probe(destination), VoiceFocusDiagnostics(clippingPercent: Double(clipped)/Double(max(1,totalFrames))*100, dropoutSeconds: Double(silentFrames)/rate, appliedGainDB: gainDB, inputLUFS: inputLUFS, outputLUFS: finalMeter.lufs, peakDBFS: 20*log10(max(peak,1e-9)), musicSections: music))
    }
}
extension SermonStore {
    public func playableDuration(for asset: AudioAsset) -> TimeInterval {
        guard let url = audioURL(for: asset), let info = try? AudioFiles.probe(url) else { return asset.duration }; return info.duration
    }
    public func trimWindow(for assetID: UUID) -> AudioTrimWindow? { document.features?.trims[assetID] }
    public func derivativeProvenance(for assetID: UUID) -> AudioDerivativeProvenance? { document.features?.derivatives[assetID] }
    public func setTrimWindow(_ window: AudioTrimWindow, for assetID: UUID) throws {
        guard let audio = document.audio[assetID] else { throw report(SermonSetError(title: "Audio unavailable", message: "Save the sermon before trimming its audio.")) }
        let duration = playableDuration(for: audio)
        try window.validate(duration: duration)
        let window = AudioTrimWindow(start: window.start,end: min(window.end,duration))
        try transaction { if $0.features == nil { $0.features = CoreFeatures() }; $0.features?.trims[assetID] = window }
    }
    @discardableResult public func renderVoiceFocus(sermonID: UUID, strength: Double = 0.5, processMusic: Bool = false) async throws -> AudioAsset {
        voiceFocusTasks[sermonID]?.cancel()
        return try await renderVoiceFocus(sermonID: sermonID, strength: strength, processMusic: processMusic, automatically: false)
    }
    func renderVoiceFocus(sermonID: UUID, strength: Double, processMusic: Bool, automatically: Bool) async throws -> AudioAsset {
        let request = UUID(); voiceFocusRenderRequests[sermonID] = request
        processingJobs[sermonID, default: ProcessingJobs()].voiceFocus = .running(progress: nil)
        defer { if voiceFocusRenderRequests[sermonID] == request { voiceFocusRenderRequests[sermonID] = nil } }
        let id = UUID(), destination = recordingsDirectory.appendingPathComponent("\(id).m4a")
        do {
            try Task.checkCancellation()
            guard strength.isFinite, (0...1).contains(strength), let source = audioAssets(for: sermonID).first(where: { [.original,.imported,.sample].contains($0.kind) }), let url = audioURL(for: source) else { throw SermonSetError(title: "Original unavailable", message: "Choose an original recording and strength from 0 to 100 percent.") }
            let sourceInfo = try await AudioFiles.inspect(url)
            let duration = sourceInfo.duration
            let requested = automatically ? AudioTrimWindow(start: 0, end: duration) : trimWindow(for: source.id) ?? AudioTrimWindow(start: 0, end: source.duration)
            try requested.validate(duration: duration)
            let trim = AudioTrimWindow(start: requested.start, end: min(requested.end, duration))
            let gainDB = try await voiceFocusAnalysis.gain(source: url, checksum: source.checksumSHA256, trim: trim, strength: strength, processMusic: processMusic)
            let (info, diagnostics) = try await voiceFocusRender(url, destination, trim, strength, processMusic, gainDB)
            try Task.checkCancellation()
            guard voiceFocusRenderRequests[sermonID] == request else { throw CancellationError() }
            let asset = AudioAsset(id: id,sermonID: sermonID,kind: .enhanced,duration: info.duration,byteCount: info.byteCount,checksumSHA256: info.checksum,sourceAudioAssetID: source.id)
            let provenance = AudioDerivativeProvenance(sourceAssetID: source.id,sourceChecksum: sourceInfo.checksum,trim: trim,strength: strength,processMusic: processMusic,algorithm: "VoiceFocus-v1 / K-weighted gated normalization / 4x peak estimate",diagnostics: diagnostics,madeAutomatically: automatically)
            let superseded = automatically ? [] : audioAssets(for: sermonID).filter {
                $0.kind == .enhanced && derivativeProvenance(for: $0.id)?.madeAutomatically == true
            }
            let supersededPaths = superseded.compactMap { document.audioPaths[$0.id] }
            try transaction {
                guard $0.sermons[sermonID] != nil, $0.audio[source.id] != nil else { throw CancellationError() }
                $0.audio[id] = asset; $0.audioPaths[id] = destination.lastPathComponent
                if $0.features == nil { $0.features = CoreFeatures() }; $0.features?.derivatives[id] = provenance
                if $0.features?.preferredListeningAssets == nil { $0.features?.preferredListeningAssets = [:] }
                $0.features?.preferredListeningAssets?[sermonID] = id
                $0.pendingVoiceFocusRecordings?.remove(sermonID)
                for old in superseded {
                    // Automatic copies share the original timeline, so any explicit
                    // anchors on one can safely retain their times on the original.
                    for key in $0.moments.keys where $0.moments[key]?.audioAssetID == old.id { $0.moments[key]?.audioAssetID = source.id }
                    for key in $0.notes.keys where $0.notes[key]?.audioAssetID == old.id { $0.notes[key]?.audioAssetID = source.id }
                    $0.audio[old.id] = nil; $0.audioPaths[old.id] = nil
                    $0.features?.derivatives[old.id] = nil; $0.features?.trims[old.id] = nil
                }
            }
            // Commit the replacement before deleting only the superseded automatic
            // files. Original/imported/sample files never enter this list.
            for path in supersededPaths {
                let oldURL = recordingsDirectory.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
            }
            processingJobs[sermonID, default: ProcessingJobs()].voiceFocus = .done
            return asset
        } catch {
            if document.audio[id] == nil { try? FileManager.default.removeItem(at: destination) }
            if voiceFocusRenderRequests[sermonID] == request, isInLibrary(sermonID) {
                processingJobs[sermonID, default: ProcessingJobs()].voiceFocus = error is CancellationError ? .idle : .failed(message: Self.error(error).message)
            }
            if error is CancellationError || automatically { throw error }
            throw report(error)
        }
    }
}
@MainActor @Observable public final class VoiceFocusController {
    public private(set) var state: JobState = .idle
    public private(set) var asset: AudioAsset?
    public private(set) var diagnostics: VoiceFocusDiagnostics?
    private let store: SermonStore
    public init(store: SermonStore) { self.store = store }
    public func render(sermonID: UUID,strength: Double = 0.5,processMusic: Bool = false) async {
        if case .running = state { return }; state = .running(progress: nil)
        do { let result = try await store.renderVoiceFocus(sermonID: sermonID,strength: strength,processMusic: processMusic); asset = result; diagnostics = store.derivativeProvenance(for: result.id)?.diagnostics; state = .done }
        catch is CancellationError { state = .idle }
        catch { state = .failed(message: error.localizedDescription) }
    }
}
