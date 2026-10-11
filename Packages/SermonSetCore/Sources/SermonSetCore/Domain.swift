import Foundation

public enum SermonType: String, Codable, Hashable, Sendable, CaseIterable {
    case hope, wisdom, grace, courage, conviction, worship, mission, restoration
}

public enum EncounterSource: String, Codable, Hashable, Sendable, CaseIterable {
    case recorded, imported, sundayPack, trade, shared, sample, discover
}

public enum TrustState: String, Codable, Hashable, Sendable, CaseIterable {
    case personalDraft, communityMatched, churchVerified
}

public enum RightsState: String, Codable, Hashable, Sendable, CaseIterable {
    case privateOnly, audioAuthorized, officialAudio, disputed, audioRemoved, noAudio
}

public enum ReviewState: String, Codable, Hashable, Sendable, CaseIterable {
    case draft, reviewed, rejected
}

public enum LocationPrecision: String, Codable, Hashable, Sendable, CaseIterable {
    case venue, city, privateLocation, unknown
}

public enum AudioAssetKind: String, Codable, Hashable, Sendable, CaseIterable {
    case original, imported, enhanced, official, sample
}

public enum MicPermission: String, Codable, Hashable, Sendable, CaseIterable {
    case undetermined, granted, denied
}

public enum BackupPreference: String, Codable, Hashable, Sendable, CaseIterable {
    case deviceBackup, excludeFromBackup
}

public enum CapabilityStatus: Codable, Hashable, Sendable {
    case available, needsDownload, unavailable(reason: String)
}

public enum JobState: Codable, Hashable, Sendable {
    case idle, running(progress: Double?), done, unavailable(reason: String), failed(message: String)
}

public struct Venue: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var churchName: String?
    public var city: String?
    public var region: String?
    public var country: String?
    public var latitude: Double?
    public var longitude: Double?
    public var precision: LocationPrecision
    public init(id: UUID = UUID(), churchName: String? = nil, city: String? = nil, region: String? = nil, country: String? = nil, latitude: Double? = nil, longitude: Double? = nil, precision: LocationPrecision = .unknown) {
        self.id = id
        self.churchName = churchName
        self.city = city
        self.region = region
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.precision = precision
    }
}

public struct Sermon: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var preacher: String?
    public var venue: Venue?
    public var serviceDate: Date
    public var primaryPassage: String?
    public var sermonType: SermonType?
    public var themes: [String]
    public var summary: String?
    public var reflectionPrompt: String?
    public var trustState: TrustState
    public var rightsState: RightsState
    public var isSample: Bool
    public var canonicalAudioAssetID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String = "", preacher: String? = nil, venue: Venue? = nil, serviceDate: Date = .now, primaryPassage: String? = nil, sermonType: SermonType? = nil, themes: [String] = [], summary: String? = nil, reflectionPrompt: String? = nil, trustState: TrustState = .personalDraft, rightsState: RightsState = .privateOnly, isSample: Bool = false, canonicalAudioAssetID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.preacher = preacher
        self.venue = venue
        self.serviceDate = serviceDate
        self.primaryPassage = primaryPassage
        self.sermonType = sermonType
        self.themes = themes
        self.summary = summary
        self.reflectionPrompt = reflectionPrompt
        self.trustState = trustState
        self.rightsState = rightsState
        self.isSample = isSample
        self.canonicalAudioAssetID = canonicalAudioAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AudioAsset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var kind: AudioAssetKind
    public var duration: TimeInterval
    public var byteCount: Int64
    public var createdAt: Date
    public var checksumSHA256: String?
    public var sourceAudioAssetID: UUID?
    public init(id: UUID = UUID(), sermonID: UUID, kind: AudioAssetKind = .original, duration: TimeInterval = 0, byteCount: Int64 = 0, createdAt: Date = .now, checksumSHA256: String? = nil, sourceAudioAssetID: UUID? = nil) {
        self.id = id
        self.sermonID = sermonID
        self.kind = kind
        self.duration = duration
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.checksumSHA256 = checksumSHA256
        self.sourceAudioAssetID = sourceAudioAssetID
    }
}

public struct MarkedMoment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var audioAssetID: UUID?
    public var time: TimeInterval
    public var note: String?
    public var createdAt: Date
    public init(id: UUID = UUID(), sermonID: UUID, audioAssetID: UUID? = nil, time: TimeInterval, note: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.sermonID = sermonID
        self.audioAssetID = audioAssetID
        self.time = time
        self.note = note
        self.createdAt = createdAt
    }
}

public struct PersonalNote: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var audioAssetID: UUID?
    public var time: TimeInterval?
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), sermonID: UUID, audioAssetID: UUID? = nil, time: TimeInterval? = nil, text: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.sermonID = sermonID
        self.audioAssetID = audioAssetID
        self.time = time
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var confidence: Double
    public var isFinal: Bool
    public var speaker: String?
    /// Sum of timed words, excluding silence within the sentence.
    public var speechDuration: TimeInterval?
    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String, confidence: Double = 1, isFinal: Bool = true, speaker: String? = nil, speechDuration: TimeInterval? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.speaker = speaker
        self.speechDuration = speechDuration
    }
}

public struct Transcript: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var audioAssetID: UUID
    public var revision: Int
    public var segments: [TranscriptSegment]
    public var engine: String
    public var localeIdentifier: String?
    public var createdAt: Date
    /// Anonymous speaker with the greatest total speech duration.
    public var primarySpeaker: String? {
        var durations: [String: TimeInterval] = [:]
        for segment in segments {
            if let speaker = segment.speaker { durations[speaker, default: 0] += max(0, segment.speechDuration ?? (segment.end - segment.start)) }
        }
        return durations.keys.sorted().max { durations[$0, default: 0] < durations[$1, default: 0] }
    }
    public init(id: UUID = UUID(), sermonID: UUID, audioAssetID: UUID, revision: Int = 1, segments: [TranscriptSegment], engine: String, localeIdentifier: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.sermonID = sermonID
        self.audioAssetID = audioAssetID
        self.revision = revision
        self.segments = segments
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.createdAt = createdAt
    }
}

public struct EvidenceRange: Codable, Hashable, Sendable {
    public var transcriptID: UUID
    public var segmentIDs: [UUID]
    public var start: TimeInterval
    public var end: TimeInterval
    public init(transcriptID: UUID, segmentIDs: [UUID], start: TimeInterval, end: TimeInterval) {
        self.transcriptID = transcriptID
        self.segmentIDs = segmentIDs
        self.start = start
        self.end = end
    }
}

public struct Takeaway: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var evidence: EvidenceRange?
    public var reviewState: ReviewState
    public var isLowEvidence: Bool
    public var isEdited: Bool
    public init(id: UUID = UUID(), text: String, evidence: EvidenceRange? = nil, reviewState: ReviewState = .draft, isLowEvidence: Bool = false, isEdited: Bool = false) {
        self.id = id
        self.text = text
        self.evidence = evidence
        self.reviewState = reviewState
        self.isLowEvidence = isLowEvidence
        self.isEdited = isEdited
    }
    private enum CodingKeys: String, CodingKey { case id, text, evidence, reviewState, isLowEvidence, isEdited }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        evidence = try values.decodeIfPresent(EvidenceRange.self, forKey: .evidence)
        reviewState = try values.decode(ReviewState.self, forKey: .reviewState)
        isLowEvidence = try values.decode(Bool.self, forKey: .isLowEvidence)
        isEdited = try values.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
    }

}

public struct OutlineItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var start: TimeInterval
    public var evidence: EvidenceRange?
    public init(id: UUID = UUID(), title: String, start: TimeInterval, evidence: EvidenceRange? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.evidence = evidence
    }
}

@available(*, deprecated, message: "Use SermonPoint in SermonNotes.")
public struct SummarySentence: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var evidence: EvidenceRange?
    public var isLowEvidence: Bool
    public init(id: UUID = UUID(), text: String, evidence: EvidenceRange? = nil, isLowEvidence: Bool = false) {
        self.id = id; self.text = text; self.evidence = evidence; self.isLowEvidence = isLowEvidence
    }
}

@available(*, deprecated, message: "Use SermonNotes.")
public struct SermonSummary: Codable, Hashable, Sendable {
    public var bigIdea: String
    public var sentences: [SummarySentence]
    public var reflectionQuestion: String?
    public var reviewState: ReviewState
    public var isEdited: Bool
    public init(bigIdea: String, sentences: [SummarySentence], reflectionQuestion: String? = nil, reviewState: ReviewState = .draft, isEdited: Bool = false) {
        self.bigIdea = bigIdea; self.sentences = sentences; self.reflectionQuestion = reflectionQuestion
        self.reviewState = reviewState; self.isEdited = isEdited
    }
}

public struct KeyPhrase: Codable, Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var evidence: EvidenceRange
    public init(text: String, start: TimeInterval, evidence: EvidenceRange) {
        self.text = text; self.start = start; self.evidence = evidence
    }
}

public struct SermonPoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var heading: String
    public var summary: String
    public var scripture: [String]
    public var keyPhrase: KeyPhrase?
    public var start: TimeInterval
    public var evidence: EvidenceRange?
    public init(id: UUID = UUID(), heading: String, summary: String, scripture: [String] = [], keyPhrase: KeyPhrase? = nil, start: TimeInterval, evidence: EvidenceRange? = nil) {
        self.id = id; self.heading = heading; self.summary = summary; self.scripture = scripture
        self.keyPhrase = keyPhrase; self.start = start; self.evidence = evidence
    }
}

public struct SermonNotes: Codable, Hashable, Sendable {
    public var title: String?
    public var bigIdea: String
    public var mainPassage: String?
    public var pointsAnnounced: Bool
    public var points: [SermonPoint]
    public var thisWeek: [String]
    public var questions: [String]
    public var reviewState: ReviewState
    public var isEdited: Bool
    public var engine: String
    public init(title: String? = nil, bigIdea: String, mainPassage: String? = nil, pointsAnnounced: Bool = false, points: [SermonPoint], thisWeek: [String] = [], questions: [String] = [], reviewState: ReviewState = .draft, isEdited: Bool = false, engine: String = "Apple Intelligence (on-device)") {
        self.title = title; self.bigIdea = bigIdea; self.mainPassage = mainPassage; self.pointsAnnounced = pointsAnnounced
        self.points = points; self.thisWeek = thisWeek; self.questions = questions
        self.reviewState = reviewState; self.isEdited = isEdited; self.engine = engine
    }
}

public struct SermonInsights: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var transcriptID: UUID
    public var transcriptRevision: Int
    public var generator: String
    public var promptVersion: String?
    public var createdAt: Date
    public var suggestedTitle: String?
    public var outline: [OutlineItem]
    public var takeaways: [Takeaway]
    public var scriptureReferences: [String]
    public var transcriptChecksumSHA256: String?
    public var generatorRuntime: String?
    @available(*, deprecated, message: "Use notes.") public var summary: SermonSummary?
    @available(*, deprecated, message: "Use notesUnavailableReason.") public var summaryUnavailableReason: String?
    public var notes: SermonNotes?
    public var notesUnavailableReason: String?
    public init(id: UUID = UUID(), sermonID: UUID, transcriptID: UUID, transcriptRevision: Int, generator: String, promptVersion: String? = nil, createdAt: Date = .now, suggestedTitle: String? = nil, outline: [OutlineItem] = [], takeaways: [Takeaway] = [], scriptureReferences: [String] = [], transcriptChecksumSHA256: String? = nil, generatorRuntime: String? = nil, summary: SermonSummary? = nil, summaryUnavailableReason: String? = nil, notes: SermonNotes? = nil, notesUnavailableReason: String? = nil) {
        self.id = id
        self.sermonID = sermonID
        self.transcriptID = transcriptID
        self.transcriptRevision = transcriptRevision
        self.generator = generator
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.suggestedTitle = suggestedTitle
        self.outline = outline
        self.takeaways = takeaways
        self.scriptureReferences = scriptureReferences
        self.transcriptChecksumSHA256 = transcriptChecksumSHA256
        self.generatorRuntime = generatorRuntime
        self.summary = summary; self.summaryUnavailableReason = summaryUnavailableReason
        self.notes = notes; self.notesUnavailableReason = notesUnavailableReason
    }
}

public struct CardEdition: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sermonID: UUID
    public var designSeed: Int
    public var editionLabel: String
    public var createdAt: Date
    public init(id: UUID = UUID(), sermonID: UUID, designSeed: Int, editionLabel: String = "Personal", createdAt: Date = .now) {
        self.id = id
        self.sermonID = sermonID
        self.designSeed = designSeed
        self.editionLabel = editionLabel
        self.createdAt = createdAt
    }
}

public struct CardInstance: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var editionID: UUID
    public var sermonID: UUID
    public var serial: Int
    public var acquiredAt: Date
    public var source: EncounterSource
    public init(id: UUID = UUID(), editionID: UUID, sermonID: UUID, serial: Int = 1, acquiredAt: Date = .now, source: EncounterSource) {
        self.id = id
        self.editionID = editionID
        self.sermonID = sermonID
        self.serial = serial
        self.acquiredAt = acquiredAt
        self.source = source
    }
}

public struct UserSermonHistory: Codable, Hashable, Sendable {
    public var sermonID: UUID
    public var source: EncounterSource
    public var firstEncounteredAt: Date
    public var listeningPosition: TimeInterval
    public var lastListenedAt: Date?
    public var completedAt: Date?
    public init(sermonID: UUID, source: EncounterSource, firstEncounteredAt: Date = .now, listeningPosition: TimeInterval = 0, lastListenedAt: Date? = nil, completedAt: Date? = nil) {
        self.sermonID = sermonID
        self.source = source
        self.firstEncounteredAt = firstEncounteredAt
        self.listeningPosition = listeningPosition
        self.lastListenedAt = lastListenedAt
        self.completedAt = completedAt
    }
}

public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var sermon: Sermon
    public var history: UserSermonHistory
    public var audio: AudioAsset?
    public var momentCount: Int
    public var noteCount: Int
    public var ownsCard: Bool
    public var id: UUID { sermon.id }
    public init(sermon: Sermon, history: UserSermonHistory, audio: AudioAsset? = nil, momentCount: Int = 0, noteCount: Int = 0, ownsCard: Bool = false) {
        self.sermon = sermon
        self.history = history
        self.audio = audio
        self.momentCount = momentCount
        self.noteCount = noteCount
        self.ownsCard = ownsCard
    }
}

public struct SundayPack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sermons: [Sermon]
    public var isDemo: Bool
    public init(id: String, title: String = "", sermons: [Sermon], isDemo: Bool = true) {
        self.id = id
        self.title = title
        self.sermons = sermons
        self.isDemo = isDemo
    }
}

public struct CapabilityReport: Codable, Hashable, Sendable {
    public var speechTranscription: CapabilityStatus
    public var onDeviceLanguageModel: CapabilityStatus
    public var processingIsOnDevice: Bool
    public init(speechTranscription: CapabilityStatus, onDeviceLanguageModel: CapabilityStatus, processingIsOnDevice: Bool = true) {
        self.speechTranscription = speechTranscription
        self.onDeviceLanguageModel = onDeviceLanguageModel
        self.processingIsOnDevice = processingIsOnDevice
    }
}

public struct ProcessingJobs: Codable, Hashable, Sendable {
    public var transcription: JobState
    public var insights: JobState
    public var summary: JobState
    public var voiceFocus: JobState
    public init(transcription: JobState = .idle, insights: JobState = .idle, summary: JobState = .idle, voiceFocus: JobState = .idle) {
        self.transcription = transcription
        self.insights = insights; self.summary = summary
        self.voiceFocus = voiceFocus
    }
    private enum CodingKeys: String, CodingKey { case transcription, insights, summary, voiceFocus }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transcription = try values.decode(JobState.self, forKey: .transcription)
        insights = try values.decode(JobState.self, forKey: .insights)
        summary = try values.decodeIfPresent(JobState.self, forKey: .summary) ?? .idle
        voiceFocus = try values.decodeIfPresent(JobState.self, forKey: .voiceFocus) ?? .idle
    }
}

public struct SermonSetError: Codable, Hashable, Sendable, Identifiable, Error, LocalizedError {
    public var id: UUID
    public var title: String
    public var message: String
    public var recoverySuggestion: String?
    public var errorDescription: String? { message }
    public var failureReason: String? { title }
    public init(id: UUID = UUID(), title: String, message: String, recoverySuggestion: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

public struct CaptureDraft: Codable, Hashable, Sendable {
    public var title: String?
    public var preacher: String?
    public var churchName: String?
    public var city: String?
    public var serviceToken: String?
    public init(title: String? = nil, preacher: String? = nil, churchName: String? = nil, city: String? = nil, serviceToken: String? = nil) {
        self.serviceToken = serviceToken
        self.title = title
        self.preacher = preacher
        self.churchName = churchName
        self.city = city
    }
}

public struct RecoverableSession: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var title: String?
    public var recoveredDuration: TimeInterval
    public var segmentCount: Int
    public init(id: UUID, startedAt: Date, title: String? = nil, recoveredDuration: TimeInterval, segmentCount: Int) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.recoveredDuration = recoveredDuration
        self.segmentCount = segmentCount
    }
}
