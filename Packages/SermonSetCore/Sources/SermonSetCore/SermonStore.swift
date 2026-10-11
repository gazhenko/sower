import Foundation
import Observation

@MainActor @Observable public final class SermonStore {
    var document = StoreDocument()
    public private(set) var lastError: SermonSetError?
    public internal(set) var capabilities = CapabilityReport(speechTranscription: .unavailable(reason: "Checking on-device speech availability."), onDeviceLanguageModel: .unavailable(reason: "Checking on-device model availability.")) {
        didSet { capabilityRevision &+= 1 }
    }
    @ObservationIgnored var capabilityRevision = 0
    @ObservationIgnored var transcriptionAdapter: any TranscriptionAdapter = SpeechAnalyzerAdapter()
    @ObservationIgnored var parakeetTranscriptionFactory: (@MainActor @Sendable (String) -> any TranscriptionAdapter)?
    public internal(set) var transcriptionFallbackReason: String?
    public internal(set) var transcriptionFallbackDebugDetail: String?
    @ObservationIgnored var insightsAdapter: any InsightsAdapter = FoundationModelInsightsAdapter()
    @ObservationIgnored var appleNotesEngine: any SermonNotesEngine
    @ObservationIgnored var openSourceNotesEngine: (any SermonNotesEngine)?
    public internal(set) var notesStageDetail: String?
    @ObservationIgnored var notesStageSermonID: UUID?
    @ObservationIgnored var recordingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var recordingBackground: [UUID: RecordingProcessingBackground] = [:]
    @ObservationIgnored var voiceFocusTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var voiceFocusRenderRequests: [UUID: UUID] = [:]
    @ObservationIgnored var voiceFocusRender: @Sendable (URL, URL, AudioTrimWindow, Double, Bool, Double) async throws -> (AudioFileInfo, VoiceFocusDiagnostics) = { source, destination, trim, strength, music, gain in
        try await VoiceFocusRenderer.render(source: source, destination: destination, trim: trim, strength: strength, processMusic: music, gainDB: gain)
    }
    @ObservationIgnored var processingForegroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored var voiceFocusPreviewTask: Task<VoiceFocusPreview, any Error>?
    @ObservationIgnored var voiceFocusPreviewRequest: UUID?
    @ObservationIgnored let voiceFocusAnalysis = VoiceFocusAnalysisCache()
    var processingJobs: [UUID: ProcessingJobs] = [:]
    @ObservationIgnored let configuration: StoreConfiguration
    @ObservationIgnored let root: URL
    @ObservationIgnored let persistent: Bool
    @ObservationIgnored var writesBlocked = false
    @ObservationIgnored var lastProgressWrites: [UUID: Date] = [:]
    @ObservationIgnored let samples: SampleCatalog
    var recordingsDirectory: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    var sessionsDirectory: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    var exportsDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SermonSetExports-\(LocalFiles.seed(root.path))", isDirectory: true) }
    var storeURL: URL { root.appendingPathComponent("store.json") }

    public init(configuration: StoreConfiguration, notesEngine: any SermonNotesEngine = FoundationModelSermonNotesEngine(), openSourceNotesEngine: (any SermonNotesEngine)? = nil) {
        self.appleNotesEngine = notesEngine
        self.openSourceNotesEngine = openSourceNotesEngine
        self.configuration = configuration
        samples = SampleCatalog.load()
        switch configuration {
        case .live:
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SermonSet", isDirectory: true)
            persistent = true
        case .preview:
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SermonSet-Preview-\(UUID().uuidString)", isDirectory: true)
            persistent = false
        case let .uiTest(directory): root = directory; persistent = true
        }
        // Preview audio is disposable, including files left by a terminated app.
        try? FileManager.default.removeItem(at: voiceFocusPreviewDirectory)
        do {
            try LocalFiles.createDirectory(root)
            try LocalFiles.createDirectory(recordingsDirectory)
            try LocalFiles.createDirectory(sessionsDirectory)
            if persistent && FileManager.default.fileExists(atPath: storeURL.path) {
                do {
                    document = try LocalFiles.decoder.decode(StoreDocument.self, from: Data(contentsOf: storeURL))
                    try document.validate()
                } catch {
                    let preserved = root.appendingPathComponent("store-corrupt-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: storeURL, to: preserved)
                    try LocalFiles.protect(preserved)
                    writesBlocked = true
                    document = StoreDocument()
                    throw SermonSetError(title: "Library needs recovery", message: "The library could not be read. The original file and a recovery copy are preserved; saving is disabled until you erase or restore the library.", recoverySuggestion: "Keep a copy of the library folder before restoring data.")
                }
            }
            try applyBackup(document.backupPreference)
            if configuration == .preview { try preloadPreview() }
        } catch { writesBlocked = true; lastError = Self.error(error) }
        Task { [weak self] in await self?.refreshCapabilities() }
        if configuration == .live { observeProcessingForeground(); Task { [weak self] in await self?.resumePendingRecordingProcessing(); await self?.runNotesLaunchArgument() } }
    }

    isolated deinit {
        voiceFocusPreviewTask?.cancel()
        if let observer = processingForegroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    public var libraryEntries: [LibraryEntry] {
        document.history.values.compactMap { entry(for: $0.sermonID) }.sorted {
            if $0.sermon.serviceDate != $1.sermon.serviceDate { return $0.sermon.serviceDate > $1.sermon.serviceDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public var mostRecentEntry: LibraryEntry? { libraryEntries.first }
    public var binder: [CardInstance] { document.cards.values.sorted { $0.acquiredAt == $1.acquiredAt ? $0.id.uuidString < $1.id.uuidString : $0.acquiredAt > $1.acquiredAt } }
    public var backupPreference: BackupPreference { document.backupPreference }
    public var hasSamplesInLibrary: Bool { libraryEntries.contains { $0.sermon.isSample } }
    public var discoverCatalog: [Sermon] { samples.sermons }
    public func entry(for sermonID: UUID) -> LibraryEntry? {
        guard let sermon = document.sermons[sermonID], let history = document.history[sermonID] else { return nil }
        return LibraryEntry(sermon: sermon, history: history, audio: sermon.canonicalAudioAssetID.flatMap { document.audio[$0] }, momentCount: moments(for: sermonID).count, noteCount: notes(for: sermonID).count, ownsCard: document.cards.values.contains { $0.sermonID == sermonID })
    }
    public func sermon(_ id: UUID) -> Sermon? { document.sermons[id] ?? samples.sermons.first { $0.id == id } }
    public func audioAssets(for sermonID: UUID) -> [AudioAsset] {
        let assets = document.audio.values.filter { $0.sermonID == sermonID }
        return (assets.isEmpty ? samples.audio.values.filter { $0.sermonID == sermonID } : Array(assets)).sorted {
            let rank: (AudioAssetKind) -> Int = { [.original, .imported, .sample, .official, .enhanced].firstIndex(of: $0) ?? 5 }
            return rank($0.kind) == rank($1.kind) ? $0.createdAt < $1.createdAt : rank($0.kind) < rank($1.kind)
        }
    }
    public func audioURL(for asset: AudioAsset) -> URL? {
        if let name = document.audioPaths[asset.id] {
            let url = recordingsDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return samples.audioURLs[asset.id]
    }
    public func moments(for sermonID: UUID) -> [MarkedMoment] { document.moments.values.filter { $0.sermonID == sermonID }.sorted { $0.time == $1.time ? $0.createdAt < $1.createdAt : $0.time < $1.time } }
    public func notes(for sermonID: UUID) -> [PersonalNote] {
        document.notes.values.filter { $0.sermonID == sermonID }.sorted {
            switch ($0.time, $1.time) {
            case let (.some(a), .some(b)): return a == b ? $0.createdAt < $1.createdAt : a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0.createdAt < $1.createdAt
            }
        }
    }
    public func transcript(for sermonID: UUID) -> Transcript? { document.transcripts[sermonID]?.max { $0.revision < $1.revision } ?? samples.transcripts[sermonID] }
    public func insights(for sermonID: UUID) -> SermonInsights? { document.insights[sermonID] ?? samples.insights[sermonID] }
    public func jobs(for sermonID: UUID) -> ProcessingJobs { processingJobs[sermonID] ?? ProcessingJobs() }
    public func edition(for sermonID: UUID) -> CardEdition? { document.editions[sermonID] }
    public func card(_ id: UUID) -> CardInstance? { document.cards[id] }
    public func isInLibrary(_ sermonID: UUID) -> Bool { document.history[sermonID] != nil }
    public func clearError() { lastError = nil }

    static func error(_ error: any Error) -> SermonSetError { error as? SermonSetError ?? SermonSetError(title: "Could not save changes", message: error.localizedDescription, recoverySuggestion: "Try again after checking available storage.") }
    func report(_ error: any Error) -> SermonSetError { let e = Self.error(error); lastError = e; return e }
    func transaction(_ mutate: (inout StoreDocument) throws -> Void) throws {
        do {
            guard !writesBlocked else { throw SermonSetError(title: "Library is protected", message: "Saving is disabled because the existing library needs recovery. Its files have not been overwritten.") }
            var next = document
            try mutate(&next)
            try next.validate()
            if persistent { try LocalFiles.write(next, to: storeURL) }
            document = next
        } catch { throw report(error) }
    }
    func requireSermon(_ id: UUID) throws -> Sermon {
        guard let sermon = document.sermons[id] else { throw report(SermonSetError(title: "Sermon unavailable", message: "This sermon is not in your library.")) }
        return sermon
    }
    func checkedTime(_ value: TimeInterval, sermonID: UUID) throws -> TimeInterval {
        guard value.isFinite && value >= 0 else { throw report(SermonSetError(title: "Invalid time", message: "Choose a time within the recording.")) }
        let duration = entry(for: sermonID)?.audio?.duration
        return duration.map { min(value, $0) } ?? value
    }
    public func updateSermon(_ sermon: Sermon) throws {
        var current = try requireSermon(sermon.id)
        current.title = sermon.title; current.preacher = sermon.preacher; current.venue = Self.privacySafeVenue(sermon.venue)
        current.serviceDate = sermon.serviceDate
        current.primaryPassage = sermon.primaryPassage; current.sermonType = sermon.sermonType; current.themes = sermon.themes
        current.summary = sermon.summary; current.reflectionPrompt = sermon.reflectionPrompt; current.updatedAt = .now
        try transaction { $0.sermons[current.id] = current }
    }
    static func remove(_ id: UUID, from state: inout StoreDocument) {
        state.pendingRecordingProcessing?.remove(id)
        state.pendingVoiceFocusRecordings?.remove(id)
        state.features?.preferredListeningAssets?[id] = nil
        state.sermons[id] = nil; state.history[id] = nil; state.editions[id] = nil; state.transcripts[id] = nil; state.insights[id] = nil
        state.cards = state.cards.filter { $0.value.sermonID != id }; state.moments = state.moments.filter { $0.value.sermonID != id }; state.notes = state.notes.filter { $0.value.sermonID != id }
        let assets = state.audio.values.filter { $0.sermonID == id }.map(\.id)
        for asset in assets { state.audio[asset] = nil; state.audioPaths[asset] = nil; state.features?.trims[asset] = nil; state.features?.derivatives[asset] = nil }
        state.features?.locales[id] = nil; state.features?.serviceTokens?[id] = nil
        let remainingPublications = state.features?.publications?.filter { $0.value.localSermonID != id }
        state.features?.publications = remainingPublications
        state.finalizedSessions = state.finalizedSessions.filter { $0.value != id }
    }
    public func deleteSermon(_ id: UUID) throws {
        _ = try requireSermon(id)
        let assets = audioAssets(for: id)
        let paths = assets.compactMap { document.audioPaths[$0.id] }
        let jobsDirectory = root.appendingPathComponent("Jobs")
        let jobFiles = assets.map { jobsDirectory.appendingPathComponent("speech-\($0.id.uuidString).json") }
            + (document.transcripts[id] ?? []).map { jobsDirectory.appendingPathComponent("insights-\($0.id.uuidString).json") }
        let sessionFiles = document.finalizedSessions.filter { $0.value == id }.keys.map { sessionsDirectory.appendingPathComponent($0.uuidString) }
        try transaction { Self.remove(id, from: &$0) }
        recordingTasks[id]?.cancel(); recordingBackground[id]?.finish(success: false)
        voiceFocusTasks[id]?.cancel(); voiceFocusRenderRequests[id] = nil
        processingJobs[id] = nil
        AudioSessionCoordinator.libraryDidRemove(root: root, sermonID: id)
        do { for path in paths { let url = recordingsDirectory.appendingPathComponent(path); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }; for url in jobFiles + sessionFiles where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
        catch { throw report(error) }
    }
    @discardableResult public func addMoment(sermonID: UUID, time: TimeInterval, note: String?) throws -> MarkedMoment {
        let sermon = try requireSermon(sermonID)
        let moment = MarkedMoment(sermonID: sermonID, audioAssetID: sermon.canonicalAudioAssetID, time: try checkedTime(time, sermonID: sermonID), note: note)
        try transaction { $0.moments[moment.id] = moment }; return moment
    }
    public func deleteMoment(_ id: UUID, sermonID: UUID) throws {
        _ = try requireSermon(sermonID)
        try transaction { if $0.moments[id]?.sermonID == sermonID { $0.moments[id] = nil } }
    }
    public func updateMoment(_ moment: MarkedMoment) throws {
        guard var current = document.moments[moment.id], current.sermonID == moment.sermonID else {
            throw report(SermonSetError(title: "Moment unavailable", message: "This marked moment could not be found."))
        }
        current.note = moment.note
        try transaction { $0.moments[current.id] = current }
    }
    @discardableResult public func addNote(sermonID: UUID, text: String, time: TimeInterval?) throws -> PersonalNote {
        let sermon = try requireSermon(sermonID)
        let note = PersonalNote(sermonID: sermonID, audioAssetID: sermon.canonicalAudioAssetID, time: try time.map { try checkedTime($0, sermonID: sermonID) }, text: text)
        try transaction { $0.notes[note.id] = note }; return note
    }
    public func updateNote(_ note: PersonalNote) throws {
        guard var current = document.notes[note.id], current.sermonID == note.sermonID else { throw report(SermonSetError(title: "Note unavailable", message: "This note could not be found.")) }
        current.text = note.text; current.time = try note.time.map { try checkedTime($0, sermonID: note.sermonID) }; current.updatedAt = .now
        try transaction { $0.notes[current.id] = current }
    }
    public func deleteNote(_ id: UUID, sermonID: UUID) throws {
        _ = try requireSermon(sermonID)
        try transaction { if $0.notes[id]?.sermonID == sermonID { $0.notes[id] = nil } }
    }
    public func recordListening(sermonID: UUID, position: TimeInterval, duration: TimeInterval) {
        guard var history = document.history[sermonID], position.isFinite, duration.isFinite, duration > 0 else { return }
        let position = max(0, min(position, duration)), now = Date.now
        let completion = position / duration >= 0.95 && history.completedAt == nil
        if !completion, let last = lastProgressWrites[sermonID], now.timeIntervalSince(last) < 2 { return }
        history.listeningPosition = position; history.lastListenedAt = now
        if completion { history.completedAt = now }
        do { try transaction { $0.history[sermonID] = history }; lastProgressWrites[sermonID] = now } catch { }
    }
    public func exportArchive() throws -> URL {
        do {
            let directory = exportsDirectory
            try LocalFiles.createDirectory(directory)
            var excluded = directory, values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
            let url = directory.appendingPathComponent("SermonSet-\(UUID().uuidString).json")
            var exported = document
            exported.audioPaths = [:]
            try LocalFiles.write(exported, to: url)
            return url
        } catch { throw report(error) }
    }
    func applyBackup(_ preference: BackupPreference) throws {
        // Applies to manifests as well as finalized recordings so unfinished audio follows the same choice.
        for path in [root, recordingsDirectory, sessionsDirectory] {
            var url = path, values = URLResourceValues()
            values.isExcludedFromBackup = preference == .excludeFromBackup
            try url.setResourceValues(values)
        }
    }
    public func setBackupPreference(_ preference: BackupPreference) throws {
        do {
            try applyBackup(preference)
            do { try transaction { $0.backupPreference = preference } }
            catch { try? applyBackup(document.backupPreference); throw error }
        } catch { throw report(error) }
    }
    public func eraseAllData() throws {
        if let captureID = AudioSessionCoordinator.captureOwner, FileManager.default.fileExists(atPath: sessionsDirectory.appendingPathComponent(captureID.uuidString).path) {
            throw report(SermonSetError(title: "Recording is active", message: "Finish or discard the current recording before erasing the library."))
        }
        for task in recordingTasks.values { task.cancel() }; for lease in recordingBackground.values { lease.finish(success: false) }
        for task in voiceFocusTasks.values { task.cancel() }; voiceFocusRenderRequests = [:]
        AudioSessionCoordinator.libraryDidRemove(root: root, sermonID: nil)
        do {
            if FileManager.default.fileExists(atPath: exportsDirectory.path) { try FileManager.default.removeItem(at: exportsDirectory) }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try LocalFiles.createDirectory(root); try LocalFiles.createDirectory(recordingsDirectory); try LocalFiles.createDirectory(sessionsDirectory)
            writesBlocked = false
            try transaction { $0 = StoreDocument() }
            processingJobs = [:]; lastProgressWrites = [:]; lastError = nil
        } catch { writesBlocked = true; throw report(error) }
    }
}
