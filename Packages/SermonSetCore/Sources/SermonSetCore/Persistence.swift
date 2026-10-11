import Foundation
import CryptoKit

public enum StoreConfiguration: Sendable, Hashable {
    case live, preview, uiTest(directory: URL)

    public static func fromLaunchArguments() -> StoreConfiguration {
        fromLaunchArguments(ProcessInfo.processInfo.arguments)
    }
    static func fromLaunchArguments(_ args: [String]) -> StoreConfiguration {
        if args.contains("-SermonSetPreviewData") { return .preview }
        if args.contains("-SermonSetUITest") {
            let directory: URL
            if let index = args.firstIndex(of: "-SermonSetUITestDirectory"), args.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            } else {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("SermonSet-UITest", isDirectory: true)
            }
            return .uiTest(directory: directory)
        }
        return .live
    }
}

struct StoreDocument: Codable, Sendable {
    var schemaVersion = 1
    var summarizeAfterRecording: Bool?
    var voiceFocusAfterRecording: Bool?
    var pendingVoiceFocusRecordings: Set<UUID>?
    var notesEngine: NotesEngineChoice?
    var transcriptionEngine: TranscriptionEngineChoice?
    var pendingRecordingProcessing: Set<UUID>?
    var features: CoreFeatures?
    var sermons: [UUID: Sermon] = [:]
    var history: [UUID: UserSermonHistory] = [:]
    var audio: [UUID: AudioAsset] = [:]
    var audioPaths: [UUID: String] = [:]
    var moments: [UUID: MarkedMoment] = [:]
    var notes: [UUID: PersonalNote] = [:]
    var transcripts: [UUID: [Transcript]] = [:]
    var insights: [UUID: SermonInsights] = [:]
    var editions: [UUID: CardEdition] = [:]
    var cards: [UUID: CardInstance] = [:]
    var weekPacks: [String: [UUID]] = [:]
    var backupPreference: BackupPreference = .deviceBackup
    // Idempotent recovery if the app dies after saving a sermon but before removing its manifest.
    var finalizedSessions: [UUID: UUID] = [:]

    func validate() throws {
        guard schemaVersion == 1 else { throw SermonSetError(title: "Store version unavailable", message: "This library uses an unsupported store version. Its files have been preserved.") }
        let valid = history.allSatisfy { key, value in key == value.sermonID && sermons[key] != nil && value.listeningPosition.isFinite && value.listeningPosition >= 0 }
            && sermons.allSatisfy { key, value in key == value.id && (value.canonicalAudioAssetID == nil || audio[value.canonicalAudioAssetID!]?.sermonID == key) }
            && cards.allSatisfy { key, value in key == value.id && history[value.sermonID] != nil && (editions[value.sermonID]?.id == value.editionID || features?.communityEditions?[value.editionID]?.sermonID == value.sermonID) }
            && editions.allSatisfy { key, value in key == value.sermonID && sermons[key] != nil }
            && audio.allSatisfy { key, value in key == value.id && sermons[value.sermonID] != nil && value.duration.isFinite && value.duration >= 0 && value.byteCount >= 0 && (value.sourceAudioAssetID == nil || audio[value.sourceAudioAssetID!]?.sermonID == value.sermonID) }
            && moments.allSatisfy { key, value in key == value.id && sermons[value.sermonID] != nil && value.time.isFinite && value.time >= 0 && (value.audioAssetID == nil || audio[value.audioAssetID!]?.sermonID == value.sermonID) }
            && notes.allSatisfy { key, value in key == value.id && sermons[value.sermonID] != nil && (value.time == nil || (value.time!.isFinite && value.time! >= 0)) && (value.audioAssetID == nil || audio[value.audioAssetID!]?.sermonID == value.sermonID) }
            && audioPaths.allSatisfy { key, value in audio[key] != nil && value == URL(fileURLWithPath: value).lastPathComponent && !value.contains("..") }
            && transcripts.allSatisfy { key, values in values.allSatisfy { $0.sermonID == key && audio[$0.audioAssetID]?.sermonID == key && $0.revision > 0 && EvidenceValidator.validSegments($0.segments) } }
        let personalCards = cards.values.filter { features?.communityEditions?[$0.editionID] == nil }
        let validFeatures = (features?.trims ?? [:]).allSatisfy { id,trim in
            guard let asset = audio[id] else { return false }; return trim.start.isFinite && trim.end.isFinite && trim.start >= 0 && trim.end > trim.start && trim.end <= asset.duration+0.1
        } && (features?.derivatives ?? [:]).allSatisfy { id,provenance in
            guard let asset = audio[id], let source = audio[provenance.sourceAssetID] else { return false }
            return asset.kind == .enhanced && asset.sourceAudioAssetID == source.id && asset.id != source.id && source.sermonID == asset.sermonID && provenance.strength.isFinite && (0...1).contains(provenance.strength) && provenance.sourceChecksum == source.checksumSHA256
        } && Set(personalCards.map(\.sermonID)).count == personalCards.count
        let validInsights = insights.allSatisfy { key, value in
            guard key == value.sermonID, let transcript = transcripts[key]?.first(where: { $0.id == value.transcriptID }), transcript.revision == value.transcriptRevision else { return false }
            // Retained listener-reviewed artifacts can still cite a saved earlier
            // revision. Validate exact evidence against that revision, never guess
            // replacement timestamps in a newly transcribed recording.
            func validEvidence(_ range: EvidenceRange) -> Bool {
                guard let source = transcripts[key]?.first(where: { $0.id == range.transcriptID }) else { return false }
                return EvidenceValidator.isValid(range, transcript: source)
            }
            return value.takeaways.allSatisfy { $0.evidence.map(validEvidence) ?? $0.isLowEvidence }
                && (value.summary?.sentences.allSatisfy { sentence in
                    sentence.evidence.map(validEvidence) ?? (value.summary?.isEdited == true)
                } ?? true)
                && (value.notes.map { notes in
                    Set(notes.points.map(\.id)).count == notes.points.count && notes.points.allSatisfy { point in
                        point.start.isFinite && point.start >= 0
                        && (point.evidence.map(validEvidence) ?? notes.isEdited)
                        && (point.keyPhrase.map { phrase in
                            phrase.start.isFinite && phrase.start >= 0 && validEvidence(phrase.evidence)
                        } ?? true)
                    }
                } ?? true)
                && value.outline.allSatisfy { $0.evidence.map(validEvidence) ?? false }
        }
        guard valid && validInsights && validFeatures else { throw SermonSetError(title: "Library could not be read", message: "The stored library contains invalid references. Its files have been preserved.") }
    }
}

enum LocalFiles {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }
    static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }
    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func stableUUID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func seed(_ key: String) -> Int {
        let bytes = SHA256.hash(data: Data(key.utf8)).prefix(7)
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
    static func freeBytes(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let capacity = values.volumeAvailableCapacityForImportantUsage { return capacity }
        return (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
