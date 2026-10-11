import Foundation

extension SermonStore {
    struct SpeechCheckpoint: Codable {
        var transcript: Transcript
        var audioChecksum: String
    }
    public func refreshCapabilities() async {
        let revision = capabilityRevision
        let adapter = await selectedTranscriptionAdapter()
        let speech = await adapter.capability()
        // Initial/foreground probes may finish after an asset download or ASR
        // readiness recheck. Keep that newer result when processing overlaps.
        guard capabilityRevision == revision else { return }
        capabilities = CapabilityReport(speechTranscription: speech, onDeviceLanguageModel: insightsAdapter.capability())
    }
    public func prepareSpeechAssets() async throws {
        let adapter = await selectedTranscriptionAdapter()
        try await prepareSpeechAssets(using: adapter)
    }
    func prepareSpeechAssets(using adapter: any TranscriptionAdapter) async throws {
        do { try await adapter.prepareAssets(); await refreshCapabilities() }
        catch { await refreshCapabilities(); throw report(error) }
    }
    public func transcribe(sermonID: UUID) async {
        await transcribe(sermonID: sermonID, preparingSpeechAssets: false)
    }
    func transcribe(sermonID: UUID, preparingSpeechAssets: Bool, freshRevision: Bool = false, forceApple: Bool = false) async {
        if case .running = jobs(for: sermonID).transcription { return }
        processingJobs[sermonID, default: ProcessingJobs()].transcription = .running(progress: 0)
        defer { clearTranscriptionWaiting(sermonID: sermonID) }
        do {
            _ = try requireSermon(sermonID)
            let adapter: any TranscriptionAdapter = if forceApple { transcriptionAdapter.configured(localeIdentifier: transcriptionLocale(for: sermonID), contextualStrings: transcriptionContext(sermonID: sermonID)) } else { await selectedTranscriptionAdapter(sermonID: sermonID) }
            var status = await adapter.capability()
            capabilities.speechTranscription = status
            // Readiness can change between selection and this second check (a
            // model deletion or memory pressure). Re-route before preparing ASR.
            if !forceApple, transcriptionEngine == .parakeet, adapter.engineName != transcriptionAdapter.engineName, status != .available {
                let reason = if case let .unavailable(reason) = status { reason } else { "Parakeet speech models are not ready. Using Apple on-device transcription." }
                throw TranscriptionUnavailableError(reason: reason)
            }
            if preparingSpeechAssets, status == .needsDownload {
                processingJobs[sermonID, default: ProcessingJobs()].transcription = .running(progress: nil)
                try await prepareSpeechAssets(using: adapter)
                try Task.checkCancellation()
                status = await adapter.capability()
                capabilities.speechTranscription = status
                processingJobs[sermonID, default: ProcessingJobs()].transcription = .running(progress: 0)
            }
            guard status == .available else {
                let reason: String
                switch status {
                case let .unavailable(message): reason = message
                case .needsDownload: reason = "The English speech assets need to be prepared before transcription."
                case .available: reason = ""
                }
                processingJobs[sermonID, default: ProcessingJobs()].transcription = .unavailable(reason: reason); return
            }
            let assets = audioAssets(for: sermonID)
            guard let audio = assets.first(where: { $0.kind == .original || $0.kind == .imported }) ?? assets.first(where: { $0.kind == .sample && sermon(sermonID)?.isSample == true }),
                  let url = audioURL(for: audio) else { throw SermonSetError(title: "Audio unavailable", message: "The original audio file is needed for on-device transcription.") }
            let directory = root.appendingPathComponent("Jobs", isDirectory: true)
            try LocalFiles.createDirectory(directory)
            let suffix = adapter.engineName == "Parakeet Ultra (on-device)" ? "-parakeet" : ""
            let checkpointURL = directory.appendingPathComponent("speech-\(audio.id.uuidString)\(suffix).json")
            if freshRevision, FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.moveItem(at: checkpointURL, to: directory.appendingPathComponent("speech-preserved-\(UUID()).json"))
            }
            let checksum = try LocalFiles.checksum(url)
            var checkpoint = SpeechCheckpoint(transcript: Transcript(sermonID: sermonID, audioAssetID: audio.id, revision: (document.transcripts[sermonID]?.map(\.revision).max() ?? 0) + 1, segments: [], engine: adapter.engineName, localeIdentifier: transcriptionLocale(for: sermonID)), audioChecksum: checksum)
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                do {
                    let saved = try LocalFiles.decoder.decode(SpeechCheckpoint.self, from: Data(contentsOf: checkpointURL))
                    guard saved.audioChecksum == checksum, saved.transcript.sermonID == sermonID, saved.transcript.audioAssetID == audio.id, saved.transcript.engine == adapter.engineName, saved.transcript.revision > (document.transcripts[sermonID]?.map(\.revision).max() ?? 0), (saved.transcript.localeIdentifier ?? "en_US") == transcriptionLocale(for: sermonID), EvidenceValidator.validSegments(saved.transcript.segments) else { throw SermonSetError(title: "Transcription checkpoint unavailable", message: "The saved speech checkpoint does not match the original audio.") }
                    checkpoint = saved
                } catch {
                    try FileManager.default.copyItem(at: checkpointURL, to: directory.appendingPathComponent("speech-preserved-\(UUID().uuidString).json"))
                    throw error
                }
            }
            let savedSegments = checkpoint.transcript.segments
            let offset = savedSegments.map(\.end).max() ?? 0
            if offset < audio.duration {
                let generated = try await adapter.transcribe(fileURL: url, startingAt: offset, onProgress: { [self] fraction in
                    let progress = min(0.99, (offset + max(0, min(1, fraction)) * max(0, audio.duration - offset)) / max(1, audio.duration))
                    updateTranscriptionProgress(sermonID: sermonID, progress: progress)
                }, onWaiting: { [self] waiting in
                    if waiting {
                        processingJobs[sermonID, default: ProcessingJobs()].transcription = .running(progress: nil)
                        notesStageSermonID = sermonID; notesStageDetail = "Waiting for the other recording"
                    } else {
                        clearTranscriptionWaiting(sermonID: sermonID)
                        updateTranscriptionProgress(sermonID: sermonID, progress: offset / max(1, audio.duration))
                    }
                }) { [self] segments in
                    try Task.checkCancellation()
                    guard isInLibrary(sermonID) else { throw CancellationError() }
                    checkpoint.transcript.segments = savedSegments + segments
                    guard EvidenceValidator.validSegments(checkpoint.transcript.segments) else { throw SermonSetError(title: "Transcript could not be saved", message: "Speech results contained invalid time ranges.") }
                    try LocalFiles.write(checkpoint, to: checkpointURL)
                    let progress = min(0.99, (segments.last?.end ?? offset) / max(1, audio.duration))
                    updateTranscriptionProgress(sermonID: sermonID, progress: progress)
                }
                checkpoint.transcript.segments = savedSegments + generated
            }
            try Task.checkCancellation()
            guard !checkpoint.transcript.segments.isEmpty, checkpoint.transcript.segments.allSatisfy(\.isFinal), checkpoint.transcript.segments.allSatisfy({ $0.end <= audio.duration + 0.5 }) else { throw SermonSetError(title: "No finalized transcript", message: "No usable finalized speech was found. The original audio is preserved.") }
            try transaction { state in
                guard state.sermons[sermonID] != nil else { throw CancellationError() }
                Self.saveTranscriptRevision(checkpoint.transcript, in: &state)
            }
            try? FileManager.default.removeItem(at: checkpointURL)
            processingJobs[sermonID, default: ProcessingJobs()].transcription = .done
        } catch is CancellationError { processingJobs[sermonID, default: ProcessingJobs()].transcription = .idle }
        catch let error as TranscriptionUnavailableError where !forceApple {
            transcriptionFallbackReason = error.fallbackReason
            transcriptionFallbackDebugDetail = error.debugDetail
            processingJobs[sermonID, default: ProcessingJobs()].transcription = .idle
            await transcribe(sermonID: sermonID, preparingSpeechAssets: preparingSpeechAssets, freshRevision: true, forceApple: true)
        }
        catch { processingJobs[sermonID, default: ProcessingJobs()].transcription = .failed(message: report(error).message) }
    }
    private func clearTranscriptionWaiting(sermonID: UUID) {
        if notesStageSermonID == sermonID, notesStageDetail == "Waiting for the other recording" {
            notesStageDetail = nil; notesStageSermonID = nil
        }
    }
    func updateTranscriptionProgress(sermonID: UUID, progress: Double) {
        guard progress.isFinite, isInLibrary(sermonID), case let .running(previous) = jobs(for: sermonID).transcription else { return }
        let fraction = max(previous ?? 0, min(0.99, max(0, progress)))
        processingJobs[sermonID, default: ProcessingJobs()].transcription = .running(progress: fraction)
        updateRecordingProgress(sermonID: sermonID, summaryStage: false, progress: fraction)
    }
    public func generateInsights(sermonID: UUID) async {
        if case .running = jobs(for: sermonID).insights { return }
        if case .running = jobs(for: sermonID).summary { return }
        guard isInLibrary(sermonID), let transcript = transcript(for: sermonID) else {
            processingJobs[sermonID, default: ProcessingJobs()].insights = .unavailable(reason: "A saved transcript is needed first.")
            processingJobs[sermonID, default: ProcessingJobs()].summary = .unavailable(reason: "A saved transcript is needed first."); return
        }
        processingJobs[sermonID, default: ProcessingJobs()].insights = .running(progress: 0)
        do {
            let adapter = modelAdapter(for: transcript)
            let status = adapter.capability()
            capabilities.onDeviceLanguageModel = status
            var insights: SermonInsights
            if status == .available {
                do {
                    insights = try await adapter.generateTakeaways(transcript: transcript, moments: moments(for: sermonID), checkpointDirectory: root.appendingPathComponent("Jobs")) { [self] progress in
                        processingJobs[sermonID, default: ProcessingJobs()].insights = .running(progress: max(0, min(1, progress)))
                        updateRecordingProgress(sermonID: sermonID, summaryStage: true, progress: progress * 0.8)
                    } onSummaryProgress: { [self] progress in
                        processingJobs[sermonID, default: ProcessingJobs()].insights = .done
                        processingJobs[sermonID, default: ProcessingJobs()].summary = .running(progress: max(0, min(1, progress)))
                        updateRecordingProgress(sermonID: sermonID, summaryStage: true, progress: 0.8 + progress * 0.2)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let updated = adapter.capability()
                    try Task.checkCancellation()
                    capabilities.onDeviceLanguageModel = updated
                    insights = ExtractiveInsightsAdapter().generate(transcript: transcript, moments: moments(for: sermonID))
                    insights.summaryUnavailableReason = updated == .available
                        ? "Apple Intelligence could not finish the takeaways. Grounded excerpts are saved; sermon notes are processed separately."
                        : Self.summaryReason(updated)
                }
            } else {
                insights = ExtractiveInsightsAdapter().generate(transcript: transcript, moments: moments(for: sermonID))
                insights.summaryUnavailableReason = Self.summaryReason(status)
            }
            processingJobs[sermonID, default: ProcessingJobs()].insights = .done
            let generatedNotes: NotesGenerationResult
            if let legacy = adapter as? FoundationModelInsightsAdapter, legacy.usesLegacySummaryClient,
               let engine = appleNotesEngine as? FoundationModelSermonNotesEngine, engine.isSystemEngine,
               notesEngine == .appleIntelligence {
                // Injected legacy clients keep the old summary contract testable.
                generatedNotes = NotesGenerationResult(unavailableReason: "This legacy adapter provides summaries; use a sermon notes engine for notes.")
            } else {
                do {
                    generatedNotes = try await draftNotes(sermonID: sermonID, transcript: transcript, knownModelStatus: capabilities.onDeviceLanguageModel)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    generatedNotes = NotesGenerationResult(unavailableReason: "The notes engine could not finish this sermon. Your transcript and takeaways are saved; try notes again later.")
                }
            }
            insights.notes = generatedNotes.notes; insights.notesUnavailableReason = generatedNotes.unavailableReason
            try Task.checkCancellation()
            guard insights.transcriptID == transcript.id, insights.transcriptRevision == transcript.revision, insights.sermonID == sermonID else { throw SermonSetError(title: "Insights need review", message: "The generated result does not match this transcript revision.") }
            insights.takeaways = insights.takeaways.compactMap { point in
                guard let evidence = point.evidence, EvidenceValidator.isValid(evidence, transcript: transcript) else { return nil }
                var point = point; point.isLowEvidence = EvidenceValidator.isLowEvidence(evidence, transcript: transcript); return point
            }
            insights.outline = insights.outline.filter { $0.evidence.map { EvidenceValidator.isValid($0, transcript: transcript) } ?? false }
            Self.validateSummary(in: &insights, transcript: transcript)
            insights.transcriptChecksumSHA256 = EvidenceValidator.contentHash(transcript)
            insights.generatorRuntime = insights.generatorRuntime ?? ProcessInfo.processInfo.operatingSystemVersionString
            try transaction { state in
                guard state.sermons[sermonID] != nil, state.transcripts[sermonID]?.max(by: { $0.revision < $1.revision })?.id == transcript.id else { throw CancellationError() }
                // Read the latest saved artifacts: edits may have occurred while inference awaited.
                if let previous = state.insights[sermonID] {
                    let retained = previous.takeaways.filter { $0.isEdited || $0.reviewState != .draft }.map { point in
                        var point = point
                        if let range = point.evidence, range.transcriptID != transcript.id {
                            point.isLowEvidence = true
                        }
                        return point
                    }
                    let texts = Set(retained.map { $0.text.lowercased() })
                    insights.takeaways = retained + insights.takeaways.filter { !texts.contains($0.text.lowercased()) }
                    Self.preserveSummary(from: previous, in: &insights, transcript: transcript)
                    Self.preserveNotes(from: previous, in: &insights)
                }
                state.insights[sermonID] = insights
            }
            processingJobs[sermonID, default: ProcessingJobs()].insights = .done
            if let legacy = adapter as? FoundationModelInsightsAdapter, legacy.usesLegacySummaryClient {
                finishSummaryJob(sermonID: sermonID, insights: insights)
            } else {
                processingJobs[sermonID, default: ProcessingJobs()].summary = insights.notes != nil ? .done : .unavailable(reason: insights.notesUnavailableReason ?? "Sermon notes are unavailable.")
            }
        } catch is CancellationError {
            processingJobs[sermonID, default: ProcessingJobs()].insights = .idle
            processingJobs[sermonID, default: ProcessingJobs()].summary = .idle
        } catch {
            let message = report(error).message
            processingJobs[sermonID, default: ProcessingJobs()].insights = .failed(message: message)
            processingJobs[sermonID, default: ProcessingJobs()].summary = .failed(message: message)
        }
    }

    @available(*, deprecated, message: "Use regenerateNotes(sermonID:).")
    public func regenerateSummary(sermonID: UUID) async {
        if case .running = jobs(for: sermonID).summary { return }
        if case .running = jobs(for: sermonID).insights { return }
        guard isInLibrary(sermonID), let transcript = transcript(for: sermonID) else {
            processingJobs[sermonID, default: ProcessingJobs()].summary = .unavailable(reason: "A saved transcript is needed first."); return
        }
        // Accepted or rewritten text belongs to the listener, including on retry.
        if let saved = insights(for: sermonID), let summary = saved.summary, summary.isEdited || summary.reviewState != .draft {
            processingJobs[sermonID, default: ProcessingJobs()].summary = .done; return
        }
        processingJobs[sermonID, default: ProcessingJobs()].summary = .running(progress: 0)
        do {
            let adapter = modelAdapter(for: transcript), status = adapter.capability()
            capabilities.onDeviceLanguageModel = status
            let generated: SummaryGenerationResult
            if status == .available {
                generated = try await adapter.generateSummary(transcript: transcript, moments: moments(for: sermonID), checkpointDirectory: root.appendingPathComponent("Jobs")) { [self] progress in
                    processingJobs[sermonID, default: ProcessingJobs()].summary = .running(progress: max(0, min(1, progress)))
                }
            } else { generated = SummaryGenerationResult(unavailableReason: Self.summaryReason(status)) }
            try Task.checkCancellation()
            var saved: SermonInsights!
            try transaction { state in
                guard state.sermons[sermonID] != nil, state.transcripts[sermonID]?.max(by: { $0.revision < $1.revision })?.id == transcript.id else { throw CancellationError() }
                // Only summary fields change; keep takeaways, title, outline, and provenance.
                var result = state.insights[sermonID] ?? SermonInsights(sermonID: sermonID, transcriptID: transcript.id, transcriptRevision: transcript.revision, generator: "Apple Foundation Models (on-device)", promptVersion: FoundationModelInsightsAdapter.promptVersion)
                let previous = result
                result.transcriptID = transcript.id; result.transcriptRevision = transcript.revision
                result.transcriptChecksumSHA256 = EvidenceValidator.contentHash(transcript)
                result.summary = generated.summary; result.summaryUnavailableReason = generated.unavailableReason
                Self.validateSummary(in: &result, transcript: transcript)
                Self.preserveSummary(from: previous, in: &result, transcript: transcript)
                state.insights[sermonID] = result; saved = result
            }
            finishSummaryJob(sermonID: sermonID, insights: saved)
        } catch is CancellationError { processingJobs[sermonID, default: ProcessingJobs()].summary = .idle }
        catch { processingJobs[sermonID, default: ProcessingJobs()].summary = .failed(message: report(error).message) }
    }
    func modelAdapter(for transcript: Transcript) -> any InsightsAdapter {
        // Retain injected adapters; Foundation Models uses the saved transcript language.
        if let adapter = insightsAdapter as? FoundationModelInsightsAdapter { return adapter.forLocale(transcript.localeIdentifier ?? "en_US") }
        return insightsAdapter
    }
    static func summaryReason(_ status: CapabilityStatus) -> String {
        switch status {
        case let .unavailable(reason): reason
        case .needsDownload: "The Apple Intelligence model is not ready on this iPhone. Try again after its on-device assets are ready."
        case .available: "The on-device model could not produce a grounded summary."
        }
    }
    static func validateSummary(in insights: inout SermonInsights, transcript: Transcript) {
        if var summary = insights.summary {
            guard (3...6).contains(summary.sentences.count), summary.sentences.allSatisfy({ $0.evidence.map { EvidenceValidator.isValid($0, transcript: transcript) } ?? false }) else {
                insights.summary = nil; insights.summaryUnavailableReason = "The summary did not have enough valid transcript evidence."; return
            }
            for i in summary.sentences.indices { summary.sentences[i].isLowEvidence = EvidenceValidator.isLowEvidence(summary.sentences[i].evidence!, transcript: transcript) }
            summary.sentences.sort { $0.evidence!.start < $1.evidence!.start }
            summary.reviewState = .draft; summary.isEdited = false
            insights.summary = summary; insights.summaryUnavailableReason = nil
        } else if insights.summaryUnavailableReason == nil { insights.summaryUnavailableReason = "The on-device model did not produce a summary. Your transcript and takeaways are saved." }
    }
    static func preserveSummary(from previous: SermonInsights, in result: inout SermonInsights, transcript: Transcript) {
        guard var summary = previous.summary, summary.isEdited || summary.reviewState != .draft else { return }
        for i in summary.sentences.indices where summary.sentences[i].evidence?.transcriptID != nil && summary.sentences[i].evidence?.transcriptID != transcript.id {
            // Keep the original saved citation when a new transcription has new
            // segment IDs. Acceptance does not mean the listener rewrote the text.
            summary.sentences[i].isLowEvidence = true
        }
        result.summary = summary; result.summaryUnavailableReason = nil
    }
    func finishSummaryJob(sermonID: UUID, insights: SermonInsights) {
        processingJobs[sermonID, default: ProcessingJobs()].summary = insights.summary != nil ? .done : .unavailable(reason: insights.summaryUnavailableReason ?? "Summary unavailable.")
    }
    public func setTakeawayReview(sermonID: UUID, takeawayID: UUID, state: ReviewState) throws {
        guard var insights = insights(for: sermonID), let index = insights.takeaways.firstIndex(where: { $0.id == takeawayID }) else { throw report(SermonSetError(title: "Takeaway unavailable", message: "This takeaway could not be found.")) }
        insights.takeaways[index].reviewState = state
        try transaction { $0.insights[sermonID] = insights; if state == .reviewed { $0.features?.staleTakeaways.remove(takeawayID) } }
    }
    public func editTakeaway(sermonID: UUID, takeawayID: UUID, text: String) throws {
        guard var insights = insights(for: sermonID), let index = insights.takeaways.firstIndex(where: { $0.id == takeawayID }) else { throw report(SermonSetError(title: "Takeaway unavailable", message: "This takeaway could not be found.")) }
        insights.takeaways[index].text = text; insights.takeaways[index].reviewState = .reviewed; insights.takeaways[index].isEdited = true
        try transaction { $0.insights[sermonID] = insights; $0.features?.staleTakeaways.remove(takeawayID) }
    }
    public func acceptSuggestedTitle(sermonID: UUID) throws {
        var sermon = try requireSermon(sermonID)
        guard let title = insights(for: sermonID)?.suggestedTitle, !title.isEmpty else { return }
        sermon.title = title; try updateSermon(sermon)
    }
}
