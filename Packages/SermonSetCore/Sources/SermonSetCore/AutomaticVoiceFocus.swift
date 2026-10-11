import Foundation

extension SermonStore {
    public var voiceFocusAfterRecording: Bool {
        get { document.voiceFocusAfterRecording ?? true }
        set { do { try transaction { $0.voiceFocusAfterRecording = newValue } } catch { _ = report(error) } }
    }

    /// Also callable after stop when automatic notes are off. The store owns this
    /// task, so leaving the recording screen does not cancel the copy.
    public func processVoiceFocusAfterRecording(sermonID: UUID) async {
        guard !Task.isCancelled else { return }
        if let task = voiceFocusTasks[sermonID] { await task.value; return }
        guard voiceFocusAfterRecording, isInLibrary(sermonID) else {
            try? transaction { $0.pendingVoiceFocusRecordings?.remove(sermonID) }
            return
        }
        // A resumed notes run must not duplicate an existing copy or override a
        // later manual render/source choice. Missing copies can be regenerated.
        if audioAssets(for: sermonID).contains(where: { derivativeProvenance(for: $0.id) != nil && audioURL(for: $0) != nil }) {
            processingJobs[sermonID, default: ProcessingJobs()].voiceFocus = .done
            try? transaction { $0.pendingVoiceFocusRecordings?.remove(sermonID) }
            return
        }
        if voiceFocusRenderRequests[sermonID] != nil { return }
        do {
            try transaction {
                if $0.pendingVoiceFocusRecordings == nil { $0.pendingVoiceFocusRecordings = [] }
                $0.pendingVoiceFocusRecordings?.insert(sermonID)
            }
        } catch {
            processingJobs[sermonID, default: ProcessingJobs()].voiceFocus = .failed(message: Self.error(error).message)
            return
        }
        let task = Task { [self] in
            do {
                _ = try await renderVoiceFocus(sermonID: sermonID, strength: 0.5, processMusic: false, automatically: true)
            } catch is CancellationError {
                // Expiration/termination resumes from the original on foreground.
            } catch {
                // The render records a readable independent failure. Notes and
                // transcription continue, and failure is not retried on every launch.
            }
            if !Task.isCancelled { try? transaction { $0.pendingVoiceFocusRecordings?.remove(sermonID) } }
            voiceFocusTasks[sermonID] = nil
        }
        voiceFocusTasks[sermonID] = task
        await task.value
    }
}
