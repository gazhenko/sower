import AVFoundation
import Foundation
import Testing
@testable import SermonSetCore

@MainActor private final class FocusGate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func enter() async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ListeningSpeech: TranscriptionAdapter {
    var engineName = "Listening speech fixture"
    var urls: [URL] = []
    var fail = false
    func capability() async -> CapabilityStatus { .available }
    func prepareAssets() async throws {}
    func transcribe(fileURL: URL, startingAt: TimeInterval, onSegments: @escaping @MainActor @Sendable ([TranscriptSegment]) throws -> Void) async throws -> [TranscriptSegment] {
        urls.append(fileURL)
        if fail { throw TranscriptionUnavailableError(reason: "Fixture fallback") }
        let segments: [TranscriptSegment] = (0..<3).map { i in
            let start = startingAt + Double(i * 2)
            return TranscriptSegment(start: start, end: start + 2, text: "Patient trust guides practical care. Prayer encourages hope.")
        }
        try onSegments(segments); return segments
    }
}

@MainActor private struct ListeningNotes: SermonNotesEngine {
    func capability(localeIdentifier: String) -> CapabilityStatus { .available }
    func generate(transcript: SermonSetCore.Transcript, checkpointDirectory: URL, onProgress: @escaping @MainActor @Sendable (Double) -> Void, onStage: @escaping @MainActor @Sendable (String) -> Void) async throws -> NotesGenerationResult {
        let segment = try #require(transcript.segments.first)
        let range = EvidenceRange(transcriptID: transcript.id, segmentIDs: [segment.id], start: segment.start, end: segment.end)
        onStage("Fixture notes"); onProgress(1)
        return NotesGenerationResult(notes: SermonNotes(bigIdea: "Patient trust guides practical care.", points: [
            SermonPoint(heading: "Patient trust", summary: "The preacher encourages patient trust.", start: segment.start, evidence: range)
        ], engine: "Listening notes fixture"))
    }
}

@MainActor @Suite struct AutomaticVoiceFocusTests {
    private func fixture(withTranscript: Bool = true) async throws -> (SermonStore, UUID, AudioAsset, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/TestFixtures/AutomaticVoiceFocus/\(UUID())", isDirectory: true)
        let store = SermonStore(configuration: .uiTest(directory: root), notesEngine: ListeningNotes())
        let input = root.appendingPathComponent("input.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384_000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let time = Double(i) / 48_000
            buffer.floatChannelData![0][i] = Float(0.12 * sin(2 * .pi * 220 * time))
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: input, settings: format.settings)
        try file?.write(from: buffer); file = nil
        let sermon = try await store.importAudio(from: input, title: "Listening fixture")
        try FileManager.default.removeItem(at: input)
        let original = try #require(store.audioAssets(for: sermon.id).first), url = try #require(store.audioURL(for: original))
        store.transcriptionAdapter = ListeningSpeech(); store.insightsAdapter = UnavailableModel()
        if withTranscript { await store.transcribe(sermonID: sermon.id) }
        return (store, sermon.id, original, url)
    }
    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<1000 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready(), "Fixture stage did not finish")
    }
    private func holdRender(_ store: SermonStore) -> FocusGate {
        let gate = FocusGate(), render = store.voiceFocusRender
        store.voiceFocusRender = { source, destination, trim, strength, music, gain in
            await gate.enter()
            return try await render(source, destination, trim, strength, music, gain)
        }
        return gate
    }

    @Test func defaultOnPersistsAndLegacyDocumentsJobsAndProvenanceDecode() async throws {
        let (store, id, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(store.voiceFocusAfterRecording && store.preferredListeningAssetID(for: id) == nil)
        store.voiceFocusAfterRecording = false
        #expect(!SermonStore(configuration: .uiTest(directory: store.root)).voiceFocusAfterRecording)
        store.voiceFocusAfterRecording = true
        #expect(SermonStore(configuration: .uiTest(directory: store.root)).voiceFocusAfterRecording)
        let focused = try await store.renderVoiceFocus(sermonID: id)
        var legacy = try #require(JSONSerialization.jsonObject(with: LocalFiles.encoder.encode(store.document)) as? [String: Any])
        legacy.removeValue(forKey: "voiceFocusAfterRecording"); legacy.removeValue(forKey: "pendingVoiceFocusRecordings")
        var features = try #require(legacy["features"] as? [String: Any]); features.removeValue(forKey: "preferredListeningAssets"); legacy["features"] = features
        let old = try LocalFiles.decoder.decode(StoreDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate()
        #expect(old.voiceFocusAfterRecording == nil && old.features?.preferredListeningAssets == nil)
        let savedProvenance = try #require(store.derivativeProvenance(for: focused.id))
        var provenance = try #require(JSONSerialization.jsonObject(with: LocalFiles.encoder.encode(savedProvenance)) as? [String: Any])
        provenance.removeValue(forKey: "madeAutomatically")
        #expect(try LocalFiles.decoder.decode(AudioDerivativeProvenance.self, from: JSONSerialization.data(withJSONObject: provenance)).madeAutomatically == nil)
        var jobs = try #require(JSONSerialization.jsonObject(with: LocalFiles.encoder.encode(ProcessingJobs())) as? [String: Any]); jobs.removeValue(forKey: "voiceFocus")
        #expect(try LocalFiles.decoder.decode(ProcessingJobs.self, from: JSONSerialization.data(withJSONObject: jobs)).voiceFocus == .idle)
        #expect(store.sermon(id)?.canonicalAudioAssetID == original.id)
    }

    @Test func automaticUsesFullOriginalRecommendedSettingsAndKeepsAnchorsAndSharingTrim() async throws {
        let (store, id, original, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let checksum = try LocalFiles.checksum(url), transcript = store.transcript(for: id)
        let moment = try store.addMoment(sermonID: id, time: 2, note: "Keep this time")
        let note = try store.addNote(sermonID: id, text: "Private", time: 2)
        let trim = AudioTrimWindow(start: 1, end: 4)
        try store.setTrimWindow(trim, for: original.id)
        await store.processVoiceFocusAfterRecording(sermonID: id)
        let focused = try #require(store.preferredListeningAsset(for: id)), provenance = try #require(store.derivativeProvenance(for: focused.id))
        #expect(focused.kind == .enhanced && provenance.madeAutomatically == true)
        #expect(provenance.strength == 0.5 && !provenance.processMusic && provenance.trim.start == 0)
        #expect(abs(provenance.trim.end - original.duration) < 0.01 && abs(focused.duration - original.duration) < 0.1)
        #expect(provenance.sourceAssetID == original.id && provenance.sourceChecksum == checksum)
        #expect(store.sermon(id)?.canonicalAudioAssetID == original.id && store.transcript(for: id) == transcript)
        #expect(store.moments(for: id) == [moment] && store.notes(for: id) == [note])
        #expect(store.trimWindow(for: original.id) == trim && store.jobs(for: id).voiceFocus == .done)
        #expect(try LocalFiles.checksum(url) == checksum)
        let reopened = SermonStore(configuration: .uiTest(directory: store.root))
        #expect(reopened.lastError == nil && reopened.preferredListeningAssetID(for: id) == focused.id)
        #expect(reopened.derivativeProvenance(for: focused.id)?.madeAutomatically == true)
    }

    @Test func slowCopyDoesNotBlockNotesAndSurvivesAwaiterCancellationWithoutDuplicateRendering() async throws {
        let (store, id, original, url) = try await fixture(withTranscript: false); defer { try? FileManager.default.removeItem(at: store.root) }
        let gate = holdRender(store)
        let caller = Task { await store.processRecording(sermonID: id) }
        defer { gate.release(); caller.cancel() }
        try await waitUntil { gate.continuation != nil && store.insights(for: id)?.notes != nil }
        #expect(store.jobs(for: id).insights == .done && store.jobs(for: id).summary == .done)
        #expect(store.jobs(for: id).voiceFocus == .running(progress: nil))
        #expect(store.transcript(for: id)?.audioAssetID == original.id)
        #expect((store.transcriptionAdapter as? ListeningSpeech)?.urls == [url])
        let second = Task { await store.processRecording(sermonID: id) }
        caller.cancel(); gate.release()
        await caller.value; await second.value
        #expect(gate.calls == 1 && store.jobs(for: id).voiceFocus == .done)
        #expect(store.document.pendingRecordingProcessing?.isEmpty == true && store.document.pendingVoiceFocusRecordings?.isEmpty == true)
        try store.setPreferredListeningAsset(original.id, for: id)
        await store.processRecording(sermonID: id)
        #expect(gate.calls == 1 && store.preferredListeningAssetID(for: id) == original.id)
    }

    @Test func disabledCopyStillAllowsNotesAndRenderFailureIsNonFatalAndReadable() async throws {
        let (store, id, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        store.voiceFocusAfterRecording = false
        store.voiceFocusRender = { _, _, _, _, _, _ in
            throw SermonSetError(title: "Voice Focus unavailable", message: "Free some storage to make a Voice Focus copy. Your original is saved.")
        }
        await store.processRecording(sermonID: id)
        #expect(store.audioAssets(for: id) == [original] && store.jobs(for: id).voiceFocus == .idle)
        #expect(store.insights(for: id)?.notes != nil)
        store.voiceFocusAfterRecording = true
        await store.processRecording(sermonID: id)
        #expect(store.jobs(for: id).voiceFocus == .failed(message: "Free some storage to make a Voice Focus copy. Your original is saved."))
        #expect(store.jobs(for: id).summary == .done && store.insights(for: id)?.notes != nil && store.lastError == nil)
        #expect(store.preferredListeningAsset(for: id)?.id == original.id && store.document.pendingRecordingProcessing?.isEmpty == true)
        #expect(store.document.pendingVoiceFocusRecordings?.isEmpty == true)
    }

    @Test func playbackPreferenceSwitchPersistsAndMissingOrRemovedCopyFallsBack() async throws {
        let (store, id, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        await store.processVoiceFocusAfterRecording(sermonID: id)
        let focused = try #require(store.preferredListeningAsset(for: id)), focusedURL = try #require(store.audioURL(for: focused))
        let player = PlaybackController(store: store)
        player.load(sermonID: id, autoplay: false)
        #expect(player.activeAssetID == focused.id && player.alignment == .original)
        player.seek(to: 3); try player.revertToOriginal()
        #expect(store.preferredListeningAssetID(for: id) == original.id && abs(player.currentTime - 3) < 0.01)
        player.stop()
        let reopened = SermonStore(configuration: .uiTest(directory: store.root)), resumed = PlaybackController(store: reopened)
        resumed.load(sermonID: id, autoplay: false)
        #expect(resumed.activeAssetID == original.id && abs(resumed.currentTime - 3) < 0.01)
        try resumed.selectAudioAsset(focused.id)
        #expect(reopened.preferredListeningAssetID(for: id) == focused.id)
        try FileManager.default.removeItem(at: focusedURL)
        resumed.load(sermonID: id, autoplay: false)
        #expect(resumed.activeAssetID == original.id && !resumed.isAudioUnavailable && abs(resumed.currentTime - 3) < 0.01)
        try reopened.transaction { $0.audio[focused.id] = nil; $0.audioPaths[focused.id] = nil; $0.features?.derivatives[focused.id] = nil }
        #expect(reopened.preferredListeningAsset(for: id)?.id == original.id)
        let invalid = UUID()
        #expect(throws: SermonSetError.self) { try reopened.setPreferredListeningAsset(invalid, for: id) }
        try reopened.setPreferredListeningAsset(nil, for: id)
        #expect(reopened.preferredListeningAssetID(for: id) == nil)
        resumed.stop()
    }

    @Test func momentsPlayAlignedPreferredCopyWithoutChangingPreferenceForOtherSources() async throws {
        let (store, id, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let inside = try store.addMoment(sermonID: id, time: 2, note: nil), outside = try store.addMoment(sermonID: id, time: 6, note: nil)
        await store.processVoiceFocusAfterRecording(sermonID: id)
        let automatic = try #require(store.preferredListeningAssetID(for: id))
        let player = PlaybackController(store: store); defer { player.stop() }
        try player.play(moment: inside)
        #expect(player.activeAssetID == automatic && player.alignment == .original && abs(player.currentTime - 2) < 0.05)
        player.pause()
        try store.setTrimWindow(AudioTrimWindow(start: 1, end: 4), for: original.id)
        let manual = try await store.renderVoiceFocus(sermonID: id, strength: 0.8)
        player.load(sermonID: id, autoplay: false)
        #expect(player.activeAssetID == manual.id && player.alignment == .offset(seconds: 1))
        try player.play(moment: inside); player.pause()
        #expect(player.activeAssetID == manual.id && abs(player.currentTime - 2) < 0.05)
        try player.play(moment: outside); player.pause()
        // The original's sharing trim must be opened temporarily to reach this
        // moment; the normal listening preference still belongs to the manual copy.
        #expect(player.activeAssetID == original.id && store.preferredListeningAssetID(for: id) == manual.id)
        #expect(abs(player.currentTime - 6) < 0.05)
        #expect(store.moments(for: id) == [inside, outside])
    }

    @Test func manualRenderSupersedesAutomaticFileAndPreservesOriginal() async throws {
        let (store, id, original, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let hash = try LocalFiles.checksum(url)
        await store.processVoiceFocusAfterRecording(sermonID: id)
        let automatic = try #require(store.preferredListeningAsset(for: id)), oldURL = try #require(store.audioURL(for: automatic))
        try store.setTrimWindow(AudioTrimWindow(start: 1, end: 4), for: original.id)
        let manual = try await store.renderVoiceFocus(sermonID: id, strength: 0.8, processMusic: true)
        #expect(store.preferredListeningAssetID(for: id) == manual.id && store.derivativeProvenance(for: manual.id)?.madeAutomatically == false)
        #expect(store.derivativeProvenance(for: manual.id)?.trim == AudioTrimWindow(start: 1, end: 4))
        #expect(store.audioAssets(for: id).map(\.id) == [original.id, manual.id] && !FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try LocalFiles.checksum(url) == hash && store.sermon(id)?.canonicalAudioAssetID == original.id)
        #expect(store.derivativeProvenance(for: automatic.id) == nil)
        #expect(SermonStore(configuration: .uiTest(directory: store.root)).lastError == nil)
    }

    @Test func manualRenderWinsOverInFlightAutomaticRender() async throws {
        let (store, id, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let gate = holdRender(store), caller = Task { await store.processVoiceFocusAfterRecording(sermonID: id) }
        defer { gate.release(); caller.cancel() }
        try await waitUntil { gate.continuation != nil }
        let manual = try await store.renderVoiceFocus(sermonID: id, strength: 0.7)
        gate.release(); await caller.value
        #expect(store.preferredListeningAssetID(for: id) == manual.id && store.jobs(for: id).voiceFocus == .done)
        #expect(store.audioAssets(for: id).map(\.id) == [original.id, manual.id])
        #expect(try FileManager.default.contentsOfDirectory(at: store.recordingsDirectory, includingPropertiesForKeys: nil).count == 2)
    }

    @Test func everyTranscriptionPathUsesOriginalAfterPreferenceChanges() async throws {
        let (store, id, original, url) = try await fixture(withTranscript: false); defer { try? FileManager.default.removeItem(at: store.root) }
        await store.processVoiceFocusAfterRecording(sermonID: id)
        let automatic = try #require(store.preferredListeningAssetID(for: id)), apple = ListeningSpeech()
        store.transcriptionEngine = .apple; store.transcriptionAdapter = apple
        await store.transcribe(sermonID: id)
        #expect(apple.urls == [url] && store.transcript(for: id)?.audioAssetID == original.id)
        await store.retranscribe(sermonID: id)
        #expect(apple.urls == [url, url] && store.transcript(for: id)?.audioAssetID == original.id)
        let parakeet = ListeningSpeech(); parakeet.engineName = "Parakeet Ultra (on-device)"
        store.setParakeetTranscriptionFactory { _ in parakeet }; store.transcriptionEngine = .parakeet
        await store.retranscribe(sermonID: id)
        #expect(parakeet.urls == [url] && store.transcript(for: id)?.audioAssetID == original.id)
        parakeet.fail = true
        await store.retranscribe(sermonID: id)
        #expect(parakeet.urls == [url, url] && apple.urls == [url, url, url])
        #expect(store.transcriptRevisions(for: id).allSatisfy { $0.audioAssetID == original.id })
        #expect(store.preferredListeningAssetID(for: id) == automatic)
    }

    @Test func cancelledCopyResumesOnRelaunchAndDeletionCannotPublishLateAudio() async throws {
        let (store, id, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let gate = holdRender(store), caller = Task { await store.processVoiceFocusAfterRecording(sermonID: id) }
        defer { gate.release(); caller.cancel() }
        try await waitUntil { gate.continuation != nil }
        store.voiceFocusTasks[id]?.cancel(); gate.release(); await caller.value
        #expect(store.document.pendingVoiceFocusRecordings?.contains(id) == true && store.jobs(for: id).voiceFocus == .idle)
        let reopened = SermonStore(configuration: .uiTest(directory: store.root))
        await reopened.resumePendingRecordingProcessing()
        #expect(reopened.preferredListeningAsset(for: id)?.kind == .enhanced && reopened.document.pendingVoiceFocusRecordings?.isEmpty == true)
        // A fresh sermon makes the in-flight deletion case independent of the
        // already completed copy and exercises source-file cleanup.
        let (deleting, deletingID, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: deleting.root) }
        let deletingGate = holdRender(deleting), deletingCaller = Task { await deleting.processVoiceFocusAfterRecording(sermonID: deletingID) }
        defer { deletingGate.release(); deletingCaller.cancel() }
        try await waitUntil { deletingGate.continuation != nil }
        try deleting.deleteSermon(deletingID); deletingGate.release(); await deletingCaller.value
        #expect(!deleting.isInLibrary(deletingID) && deleting.preferredListeningAssetID(for: deletingID) == nil)
        #expect(deleting.jobs(for: deletingID).voiceFocus == .idle && deleting.document.pendingVoiceFocusRecordings?.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(at: deleting.recordingsDirectory, includingPropertiesForKeys: nil).isEmpty)
    }
}
