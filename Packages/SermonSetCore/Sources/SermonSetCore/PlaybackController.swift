import Foundation
import Observation
import AVFoundation
import MediaPlayer

@MainActor @Observable public final class PlaybackController: NSObject, AVAudioPlayerDelegate {
    public private(set) var nowPlayingSermonID: UUID?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var activeAssetID: UUID?
    public private(set) var alignment: AudioAlignment = .original
    private var sourceOffset: TimeInterval = 0
    private var lowerBound: TimeInterval = 0
    public private(set) var activeAssetKind: AudioAssetKind?
    public private(set) var isAudioUnavailable = false
    @ObservationIgnored private let store: SermonStore
    @ObservationIgnored private let coordinatorID = UUID()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var remotePlayer: AVPlayer?
    @ObservationIgnored private var remoteCommunity: CommunityController?
    @ObservationIgnored private var remoteSermonID: String?
    @ObservationIgnored private var remoteExpiry: Date?
    @ObservationIgnored private var refreshingRemote = false
    @ObservationIgnored private var remoteGeneration = UUID()
    public private(set) var officialAudioAvailable = false
    public var usingOfficialAudio: Bool { activeAssetKind == .official }
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    #if os(iOS)
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    #endif
    @ObservationIgnored private var resumeAfterInterruption = false

    public init(store: SermonStore) {
        self.store = store
        super.init()
        AudioSessionCoordinator.playbackPauseHandlers[coordinatorID] = { [weak self] in self?.pause() }
        AudioSessionCoordinator.removalHandlers[coordinatorID] = { [weak self] root, sermonID in
            guard let self, self.store.root == root, sermonID == nil || sermonID == self.nowPlayingSermonID else { return }
            self.stop()
        }
        observeSession(); configureRemoteCommands()
    }
    public func load(sermonID: UUID, autoplay: Bool) {
        if nowPlayingSermonID == sermonID, remotePlayer != nil || (player != nil && activeAssetID == store.preferredListeningAsset(for: sermonID)?.id) {
            if autoplay { play() } else { pause() }
            return
        }
        stop()
        nowPlayingSermonID = sermonID
        guard let sermon = store.sermon(sermonID), ![RightsState.noAudio, .audioRemoved, .disputed].contains(sermon.rightsState), let asset = store.preferredListeningAsset(for: sermonID), let url = store.audioURL(for: asset) else {
            isAudioUnavailable = true; return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true; player.rate = rate; player.delegate = self
            player.prepareToPlay()
            configureLocalTimeline(asset: asset, player: player, timestamp: store.entry(for: sermonID)?.history.listeningPosition ?? 0)
            activeAssetID = asset.id; activeAssetKind = asset.kind; isAudioUnavailable = false
            self.player = player
            updateNowPlaying()
            if autoplay { play() }
        } catch { isAudioUnavailable = true; _ = store.report(SermonSetError(title: "Audio could not be played", message: error.localizedDescription)) }
    }
    /// Same source timestamp for Original/Voice Focus; level matching attenuates the louder source.
    public func selectAudioAsset(_ assetID: UUID, levelMatched: Bool = true, acknowledgeMomentShift: Bool = false) throws {
        try selectAudioAsset(assetID, levelMatched: levelMatched, acknowledgeMomentShift: acknowledgeMomentShift, rememberPreference: true)
    }
    private func selectAudioAsset(_ assetID: UUID, levelMatched: Bool, acknowledgeMomentShift: Bool, rememberPreference: Bool) throws {
        guard let sermonID = nowPlayingSermonID, let asset = store.audioAssets(for: sermonID).first(where: { $0.id == assetID }), let url = store.audioURL(for: asset) else { throw SermonSetError(title: "Audio unavailable", message: "Open a local sermon before comparing audio.") }
        if asset.kind == .official { try store.requireOfficialAuthorization(asset.id) }
        if asset.kind == .official && !acknowledgeMomentShift { throw SermonSetError(title: "Your moments may shift",message: "Confirm the switch to official audio. Your existing marked moments stay attached to their original source.") }
        let provenance = store.derivativeProvenance(for: assetID)
        let next = try AVAudioPlayer(contentsOf: url)
        next.enableRate = true; next.rate = rate; next.delegate = self; next.prepareToPlay()
        if rememberPreference, store.isInLibrary(sermonID) { try store.setPreferredListeningAsset(assetID, for: sermonID) }
        let playing = isPlaying, timestamp = currentTime
        pause()
        configureLocalTimeline(asset: asset, player: next, timestamp: timestamp)
        if levelMatched {
            let reference = store.audioAssets(for: sermonID).compactMap { store.derivativeProvenance(for: $0.id)?.diagnostics }.last
            let original = reference?.inputLUFS ?? -16, enhanced = reference?.outputLUFS ?? -16
            let target = min(original,enhanced), level = provenance == nil ? original : enhanced
            next.volume = Float(pow(10,(target-level)/20))
        }
        remotePlayer = nil; remoteExpiry = nil; remoteGeneration = UUID()
        player = next; activeAssetID = assetID; activeAssetKind = asset.kind; isAudioUnavailable = false
        if playing { play() }; updateNowPlaying()
    }
    private func configureLocalTimeline(asset: AudioAsset, player: AVAudioPlayer, timestamp: TimeInterval) {
        let provenance = store.derivativeProvenance(for: asset.id)
        sourceOffset = provenance?.trim.start ?? 0
        let trim = provenance?.trim ?? store.trimWindow(for: asset.id)
        lowerBound = trim?.start ?? 0
        duration = min(sourceOffset + player.duration, trim?.end ?? player.duration)
        currentTime = max(lowerBound, min(timestamp, duration))
        player.currentTime = currentTime - sourceOffset
        alignment = asset.kind == .official ? .unavailable : (sourceOffset == 0 ? .original : .offset(seconds: sourceOffset))
    }
    public func playCommunity(sermonID: String, localID: UUID, community: CommunityController, from time: TimeInterval = 0) async throws {
        let token = remoteGeneration
        let remote = try await community.sermon(sermonID)
        guard remote.audioAvailable else { throw SermonSetError(title: "Audio unavailable",message: "Audio permission is unavailable. Your card and history remain.") }
        let audio = try await community.audioURL(sermonID: sermonID)
        guard remoteGeneration == token else { throw CancellationError() }
        let mapped = store.localCommunityID(audio.audioAssetID,server: community.configuration.audience)
        if nowPlayingSermonID == localID, let current = activeAssetID, current != mapped, player != nil || remotePlayer != nil {
            officialAudioAvailable = remote.trustLabels.contains("Official audio")
            throw SermonSetError(title: "Your moments may shift",message: "Confirm the switch to the new audio master. Existing moments stay on their source.")
        }
        try community.rememberForListening(remote)
        pause(); player = nil; nowPlayingSermonID = localID
        remoteCommunity = community; remoteSermonID = sermonID; remoteExpiry = audio.expiresAt
        remotePlayer = AVPlayer(url: audio.url); currentTime = max(0,time); sourceOffset = 0; lowerBound = 0; duration = 0
        activeAssetID = mapped; activeAssetKind = remote.trustLabels.contains("Official audio") ? .official : .enhanced
        officialAudioAvailable = remote.trustLabels.contains("Official audio"); alignment = .unavailable; isAudioUnavailable = false
        _ = try store.registerRemoteAudio(sermonID: localID,remoteAssetID: audio.audioAssetID,server: community.configuration.audience,duration: 0,official: officialAudioAvailable)
        if time > 0 { await remotePlayer?.seek(to: CMTime(seconds: time,preferredTimescale: 600)) }
        play()
    }
    public func useOfficialAudio(_ on: Bool) async throws {
        if !on { try revertToOriginal(); return }
        guard let remoteCommunity, let remoteSermonID else { throw SermonSetError(title: "Official audio unavailable",message: "Open the community sermon to check for official audio.") }
        if remotePlayer != nil { activeAssetID = nil; try await playCommunity(sermonID: remoteSermonID,localID: nowPlayingSermonID!,community: remoteCommunity,from: currentTime) }
        else { try await selectOfficialAudio(communitySermonID: remoteSermonID,community: remoteCommunity,acknowledgeMomentShift: true) }
    }
    public func selectOfficialAudio(communitySermonID: String, community: CommunityController, acknowledgeMomentShift: Bool) async throws {
        guard acknowledgeMomentShift, let sermonID = nowPlayingSermonID else { throw SermonSetError(title: "Your moments may shift", message: "Confirm the switch to official audio first.") }
        remoteCommunity = community; remoteSermonID = communitySermonID
        let remote = try await community.sermon(communitySermonID)
        guard remote.trustLabels.contains("Official audio"), remote.audioAvailable else { throw SermonSetError(title: "Official audio unavailable",message: "No authorized official master is currently available.") }
        let authorized = try await community.audioURL(sermonID: communitySermonID)
        let id = UUID(), destination = store.recordingsDirectory.appendingPathComponent("\(id).m4a")
        do {
            let (temporary,response) = try await community.client.session.download(from: authorized.url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: temporary,to: destination); try LocalFiles.protect(destination)
            let info = try await AudioFiles.inspect(destination)
            let asset = AudioAsset(id: id,sermonID: sermonID,kind: .official,duration: info.duration,byteCount: info.byteCount,checksumSHA256: info.checksum)
            try store.transaction {
                $0.audio[id] = asset; $0.audioPaths[id] = destination.lastPathComponent
                if $0.features == nil { $0.features = CoreFeatures() }; if $0.features?.officialSources == nil { $0.features?.officialSources = [:] }
                $0.features?.officialSources?[id] = OfficialSourceAuthorization(server: community.configuration.audience,sermonID: communitySermonID,audioAssetID: authorized.audioAssetID,expiresAt: authorized.expiresAt)
            }
            if nowPlayingSermonID == sermonID { try selectAudioAsset(id,levelMatched: false,acknowledgeMomentShift: true) }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    public func play(moment: MarkedMoment) throws {
        load(sermonID: moment.sermonID,autoplay: false)
        if let source = moment.audioAssetID, source != activeAssetID {
            let focused = activeAssetID.flatMap { store.derivativeProvenance(for: $0) }
            let aligned = focused?.sourceAssetID == source && moment.time >= lowerBound && moment.time <= duration
            if !aligned { try selectAudioAsset(source,levelMatched: false,acknowledgeMomentShift: true,rememberPreference: false) }
        }
        if let player, let kind = activeAssetKind, [.original, .imported, .sample].contains(kind), moment.time < lowerBound || moment.time > duration {
            // A saved sharing trim must not hide a moment on the full original.
            lowerBound = 0; sourceOffset = 0; duration = player.duration; alignment = .original
        }
        seek(to: moment.time); play()
    }
    public func revertToOriginal() throws {
        guard let id = nowPlayingSermonID, let original = store.audioAssets(for: id).first(where: { [.original,.imported,.sample].contains($0.kind) }) else { throw SermonSetError(title: "Original source unavailable",message: "No personal original is saved for this community sermon. Your moments remain attached to their prior source.") }
        try selectAudioAsset(original.id)
    }
    public func play(sermonID: UUID, from time: TimeInterval) { load(sermonID: sermonID, autoplay: false); seek(to: time); play() }
    public func play() {
        if let remotePlayer {
            guard !isAudioUnavailable, AudioSessionCoordinator.captureOwner == nil else { return }
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.playback,mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                remotePlayer.playImmediately(atRate: rate); isPlaying = true; startTicker(); updateNowPlaying()
            } catch { isAudioUnavailable = true; _ = store.report(error) }; return
        }
        guard let player, !isAudioUnavailable else { return }
        guard AudioSessionCoordinator.captureOwner == nil else {
            _ = store.report(SermonSetError(title: "Recording is active", message: "Finish the recording before playing audio.")); return
        }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if player.currentTime + sourceOffset >= duration { player.currentTime = lowerBound - sourceOffset; currentTime = lowerBound }
            player.rate = rate
            guard player.play() else { throw SermonSetError(title: "Audio could not be played", message: "Try opening the recording again.") }
            isPlaying = true; startTicker(); updateNowPlaying()
        } catch { isPlaying = false; _ = store.report(error) }
    }
    public func pause() {
        remotePlayer?.pause(); player?.pause(); isPlaying = false; ticker?.cancel()
        currentTime = remotePlayer.map { $0.currentTime().seconds } ?? player.map { $0.currentTime + sourceOffset } ?? currentTime
        persistProgress(force: true); updateNowPlaying()
    }
    public func toggle() { if isPlaying { pause() } else { play() } }
    public func seek(to time: TimeInterval) {
        guard time.isFinite, player != nil || remotePlayer != nil else { return }
        currentTime = max(lowerBound, duration > 0 ? min(time, duration) : time); player?.currentTime = currentTime - sourceOffset
        remotePlayer?.seek(to: CMTime(seconds: currentTime,preferredTimescale: 600))
        persistProgress(force: true); updateNowPlaying()
    }
    public func skip(by seconds: TimeInterval) { guard seconds.isFinite else { return }; seek(to: currentTime + seconds) }
    public func setRate(_ rate: Float) {
        guard [Float(0.75), 1, 1.25, 1.5, 2].contains(rate) else { return }
        self.rate = rate; player?.rate = rate; if isPlaying { remotePlayer?.rate = rate }; updateNowPlaying()
    }
    public func stop() {
        pause(); player?.stop(); player = nil; remotePlayer = nil; remoteCommunity = nil; remoteSermonID = nil; remoteExpiry = nil; remoteGeneration = UUID(); refreshingRemote = false; officialAudioAvailable = false
        nowPlayingSermonID = nil; duration = 0; currentTime = 0; activeAssetKind = nil; activeAssetID = nil; sourceOffset = 0; lowerBound = 0; alignment = .original; isAudioUnavailable = false
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }
    private func persistProgress(force: Bool = false) {
        guard let id = nowPlayingSermonID else { return }
        if force { store.lastProgressWrites[id] = nil }
        store.recordListening(sermonID: id, position: currentTime, duration: duration)
    }
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.tick()
                if self == nil { return }
            }
        }
    }
    private func tick() {
        guard isPlaying else { return }
        if let remotePlayer {
            let length = remotePlayer.currentItem?.duration.seconds ?? 0
            if length.isFinite, length > 0 { duration = length }
            if remotePlayer.currentItem?.status == .failed { pause(); isAudioUnavailable = true; _ = store.report(SermonSetError(title: "Audio unavailable",message: "Refresh to check the audio's current permission.")); return }
            if let remoteCommunity, let remoteSermonID {
                if let cached = store.document.features?.community?.sermons[remoteSermonID], !cached.audioAvailable { pause(); isAudioUnavailable = true; return }
                if let remoteExpiry, remoteExpiry.timeIntervalSinceNow < 30, !refreshingRemote {
                    refreshingRemote = true; let token = remoteGeneration, time = currentTime
                    Task { [weak self] in
                        guard let self else { return }; defer { if self.remoteGeneration == token { self.refreshingRemote = false } }
                        do { try await self.playCommunity(sermonID: remoteSermonID,localID: self.nowPlayingSermonID!,community: remoteCommunity,from: time) }
                        catch { if self.remoteGeneration == token { self.pause(); self.isAudioUnavailable = true; _ = self.store.report(error) } }
                    }
                }
            }
            if nowPlayingSermonID != nil, let assetID = activeAssetID, var asset = store.document.audio[assetID], duration > 0, abs(asset.duration-duration) > 0.1 { asset.duration = duration; try? store.transaction { $0.audio[assetID] = asset } }
        }
        currentTime = remotePlayer.map { $0.currentTime().seconds } ?? player.map { $0.currentTime + sourceOffset } ?? currentTime
        if !currentTime.isFinite { currentTime = 0 }
        if duration > 0, currentTime >= duration { pause() }; persistProgress(); updateNowPlaying()
    }
    private func updateNowPlaying() {
        #if os(iOS)
        guard let id = nowPlayingSermonID, let sermon = store.sermon(id), player != nil || remotePlayer != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: sermon.title, MPMediaItemPropertyArtist: sermon.preacher ?? "", MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : Float(0), MPNowPlayingInfoPropertyDefaultPlaybackRate: rate, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        #endif
    }
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.isPlaying = false; self.currentTime = flag ? self.duration : current.currentTime + self.sourceOffset
            self.ticker?.cancel(); self.persistProgress(force: true); self.updateNowPlaying()
        }
    }
    private func configureRemoteCommands() {
        #if os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [15]; center.skipBackwardCommand.preferredIntervals = [15]
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.play() }; return .success }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.pause() }; return .success }))
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.toggle() }; return .success }))
        remoteTargets.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.skip(by: 15) }; return .success }))
        remoteTargets.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.skip(by: -15) }; return .success }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: time) }; return .success
        }))
        remoteTargets.append((center.changePlaybackRateCommand, center.changePlaybackRateCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor [weak self] in self?.setRate(rate) }; return .success
        }))
        #endif
    }
    private func observeSession() {
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { @Sendable [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.resumeAfterInterruption = self.isPlaying; self.pause() }
                else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    if self.resumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume), AudioSessionCoordinator.captureOwner == nil { self.play() }
                    self.resumeAfterInterruption = false
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { @Sendable [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor [weak self] in self?.pause() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { @Sendable [weak self] _ in Task { @MainActor [weak self] in self?.stop() } })
        #endif
    }
    isolated deinit {
        ticker?.cancel(); player?.stop(); remotePlayer?.pause()
        AudioSessionCoordinator.playbackPauseHandlers[coordinatorID] = nil
        AudioSessionCoordinator.removalHandlers[coordinatorID] = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        #if os(iOS)
        for (command, target) in remoteTargets { command.removeTarget(target) }
        #endif
    }
}
