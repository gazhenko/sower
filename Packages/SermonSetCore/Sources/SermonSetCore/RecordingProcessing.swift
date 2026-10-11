import Foundation
import NaturalLanguage
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
@preconcurrency import BackgroundTasks
#endif

extension SermonStore {
    public var summarizeAfterRecording: Bool {
        get { document.summarizeAfterRecording ?? true }
        set { do { try transaction { $0.summarizeAfterRecording = newValue } } catch { _ = report(error) } }
    }

    /// Call immediately after stop while foregrounded. The store owns the work;
    /// cancellation of a view's awaiting task does not cancel processing.
    public func processRecording(sermonID: UUID) async {
        if let task = recordingTasks[sermonID] { await task.value; return }
        do {
            _ = try requireSermon(sermonID)
            try transaction {
                if $0.pendingRecordingProcessing == nil { $0.pendingRecordingProcessing = [] }
                $0.pendingRecordingProcessing?.insert(sermonID)
            }
        } catch { return }
        let lease = RecordingProcessingBackground()
        recordingBackground[sermonID] = lease
        lease.begin(enabled: configuration == .live, subtitle: transcript(for: sermonID) == nil ? "Transcribing on your iPhone" : "Drafting the summary") { [weak self] in
            self?.recordingTasks[sermonID]?.cancel()
            self?.voiceFocusTasks[sermonID]?.cancel()
        }
        let task = Task { [self] in
            async let focused: Void = processVoiceFocusAfterRecording(sermonID: sermonID)
            if transcript(for: sermonID) == nil {
                await transcribe(sermonID: sermonID, preparingSpeechAssets: true)
                await waitForProcessingStage(sermonID: sermonID, transcription: true)
            }
            if !Task.isCancelled, transcript(for: sermonID) != nil, isInLibrary(sermonID) {
                updateRecordingProgress(sermonID: sermonID, summaryStage: true, progress: 0)
                await generateInsights(sermonID: sermonID)
                await waitForProcessingStage(sermonID: sermonID, transcription: false)
            }
            let completed = !Task.isCancelled && jobs(for: sermonID).insights == .done
            if completed { try? transaction { $0.pendingRecordingProcessing?.remove(sermonID) } }
            await focused
            lease.finish(success: completed)
            recordingTasks[sermonID] = nil; recordingBackground[sermonID] = nil
        }
        recordingTasks[sermonID] = task
        await task.value
    }

    func waitForProcessingStage(sermonID: UUID, transcription: Bool) async {
        while !Task.isCancelled {
            let jobs = jobs(for: sermonID)
            if transcription {
                guard case .running = jobs.transcription else { return }
            } else {
                let runningInsights: Bool = if case .running = jobs.insights { true } else { false }
                let runningSummary: Bool = if case .running = jobs.summary { true } else { false }
                guard runningInsights || runningSummary else { return }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    func updateRecordingProgress(sermonID: UUID, summaryStage: Bool, progress: Double) {
        recordingBackground[sermonID]?.update(subtitle: summaryStage ? "Drafting the summary" : "Transcribing on your iPhone", progress: (summaryStage ? 0.6 : 0) + max(0, min(1, progress)) * (summaryStage ? 0.39 : 0.6))
    }
    func resumePendingRecordingProcessing() async {
        for id in document.pendingRecordingProcessing ?? [] where isInLibrary(id) {
            if Task.isCancelled { return }
            await processRecording(sermonID: id)
        }
        for id in document.pendingVoiceFocusRecordings ?? [] where isInLibrary(id) {
            if Task.isCancelled { return }
            await processVoiceFocusAfterRecording(sermonID: id)
        }
    }
    func observeProcessingForeground() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        processingForegroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in await self?.resumePendingRecordingProcessing() }
        }
        #endif
    }

    @available(*, deprecated, message: "Use editNotes(sermonID:notes:).")
    public func editSummary(sermonID: UUID, bigIdea: String, text: String, reflectionQuestion: String?) throws {
        _ = try requireSermon(sermonID)
        guard var insights = insights(for: sermonID), insights.summary != nil else { throw report(SermonSetError(title: "Summary unavailable", message: "Generate a summary before editing it.")) }
        let idea = bigIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, !body.isEmpty else { throw report(SermonSetError(title: "Summary needs words", message: "Enter a big idea and the summary text.")) }
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = body
        var sentences: [SummarySentence] = []
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
            let text = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sentences.append(SummarySentence(text: text)) }; return true
        }
        if sentences.isEmpty { sentences = [SummarySentence(text: body)] }
        insights.summary = SermonSummary(bigIdea: idea, sentences: sentences, reflectionQuestion: Self.nonemptySummaryText(reflectionQuestion), reviewState: .reviewed, isEdited: true)
        insights.summaryUnavailableReason = nil
        try transaction { $0.insights[sermonID] = insights }
    }
    @available(*, deprecated, message: "Use setNotesReview(sermonID:state:).")
    public func setSummaryReview(sermonID: UUID, state: ReviewState) throws {
        _ = try requireSermon(sermonID)
        guard var insights = insights(for: sermonID), insights.summary != nil else { throw report(SermonSetError(title: "Summary unavailable", message: "There is no summary to review yet.")) }
        insights.summary?.reviewState = state
        try transaction { $0.insights[sermonID] = insights }
    }
    @available(*, deprecated, message: "Use useNotesOnCard(sermonID:).")
    public func useSummaryOnCard(sermonID: UUID) throws {
        var sermon = try requireSermon(sermonID)
        guard let summary = insights(for: sermonID)?.summary else { throw report(SermonSetError(title: "Summary unavailable", message: "Generate or edit a summary before using it on your card.")) }
        sermon.summary = summary.bigIdea; sermon.reflectionPrompt = summary.reflectionQuestion
        try updateSermon(sermon)
    }
    static func nonemptySummaryText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }; return text
    }
}

/// Each invocation has a unique identifier, registered once. Continued-processing
/// registrations are explicitly exempt from the before-launch rule in the SDK.
@MainActor final class RecordingProcessingBackground {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var task: BGContinuedProcessingTask?
    private var identifier: String?
    #endif
    private var finished = false
    private var subtitle = "Transcribing on your iPhone"
    private var fraction = 0.0
    func begin(enabled: Bool, subtitle: String, onExpiration: @escaping @MainActor @Sendable () -> Void) {
        self.subtitle = subtitle
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard enabled, UIApplication.shared.applicationState == .active,
              let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
              permitted.contains("com.gazhenko.sower.process.*"),
              (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("processing") == true else { return }
        let id = "com.gazhenko.sower.process.\(UUID().uuidString)"
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil, launchHandler: { @Sendable [weak self] task in
            // Install expiration handling immediately on the scheduler queue,
            // even if the main actor is busy saving a checkpoint.
            task.expirationHandler = { @Sendable [weak self] in
                Task { @MainActor [weak self] in onExpiration(); self?.finish(success: false) }
            }
            Task { @MainActor [weak self] in
                guard let self, !self.finished, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                self.task = task
                task.progress.totalUnitCount = 1000
                self.update(subtitle: self.subtitle, progress: self.fraction)
            }
        }) else { return }
        identifier = id
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Summarizing your sermon", subtitle: subtitle)
        // A queued task might arrive after foreground work finishes. Immediate
        // eligibility is required; on rejection, durable checkpoints still resume.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { identifier = nil }
        #endif
    }
    func update(subtitle: String, progress: Double) {
        self.subtitle = subtitle; fraction = max(fraction, progress)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        task?.updateTitle("Summarizing your sermon", subtitle: subtitle)
        task?.progress.completedUnitCount = Int64(min(0.99, fraction) * 1000)
        #endif
    }
    func finish(success: Bool) {
        guard !finished else { return }; finished = true
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if success { task?.progress.completedUnitCount = 1000 }
        task?.setTaskCompleted(success: success); task = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        #endif
    }
}
