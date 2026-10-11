# SermonSetCore integration notes

The native Swift package implements the prototype contract plus the feature-complete APIs documented below. Domain values are public, Codable, Hashable, Sendable, and Identifiable where specified. The core does not import SwiftUI or contain analytics. The historical prototype sections describe the original offline boundary; the feature-complete sections supersede that boundary with explicit, reviewed community networking. Xcode 26.6 ships an iOS 26.5 Simulator SDK in this environment; the deployment target remains iOS 26.0.

## Exact API additions and differences

The store, capture, and playback signatures in `CORE-CONTRACT.md` are retained. Store state is read-only to callers. These additional store methods inherit `SermonStore`'s MainActor isolation:

```swift
public func refreshCapabilities() async
public func prepareSpeechAssets() async throws
public func updateMoment(_ moment: MarkedMoment) throws
```

`updateMoment` changes only an existing moment's `note`, including clearing it with nil. It retains the stored id, sermonID, time, audioAssetID, and createdAt. Unknown IDs or mismatched sermon IDs throw `SermonSetError` and set `lastError`.

`SermonInsights` adds two optional provenance fields:

```swift
public var transcriptChecksumSHA256: String?
public var generatorRuntime: String?

public init(id: UUID = UUID(), sermonID: UUID, transcriptID: UUID,
            transcriptRevision: Int, generator: String, promptVersion: String? = nil,
            createdAt: Date = .now, suggestedTitle: String? = nil,
            outline: [OutlineItem] = [], takeaways: [Takeaway] = [],
            scriptureReferences: [String] = [], transcriptChecksumSHA256: String? = nil,
            generatorRuntime: String? = nil)
```

The initializers retain existing parameter names/defaults. Optional provenance fields decode older version-1 documents without those fields. The hash covers segment identity, times, text, confidence, and finality; runtime identifies the OS and adapter, not a verified Apple model weight version.

The quote-handling and capture-start/service-date follow-ups add no public API signatures or schema fields. Their behavioral changes are described below; the quote-handling follow-up also changes the internal model checkpoint version.

`public func updateSermon(_ sermon: Sermon) throws` now accepts `serviceDate` alongside the other editable metadata. The stored `createdAt`, identity, original audio reference, rights/trust state, and sample flag remain unchanged; `updatedAt` is refreshed. Editing the service date preserves acquisition/listening history. Version-1 date storage remains whole-second ISO-8601.

Public adapter interfaces:

```swift
@MainActor public protocol TranscriptionAdapter: Sendable {
    func capability() async -> CapabilityStatus
    func prepareAssets() async throws
    func transcribe(fileURL: URL, startingAt: TimeInterval,
                    onSegments: @escaping @MainActor @Sendable ([TranscriptSegment]) throws -> Void)
        async throws -> [TranscriptSegment]
}

@MainActor public protocol InsightsAdapter: Sendable {
    func capability() -> CapabilityStatus
    func generate(transcript: Transcript, moments: [MarkedMoment], checkpointDirectory: URL,
                  onProgress: @escaping @MainActor @Sendable (Double) -> Void)
        async throws -> SermonInsights
}
```

Concrete adapters are `SpeechAnalyzerAdapter` and `FoundationModelInsightsAdapter`, each with `public init()`. `ExtractiveInsightsAdapter` exposes `public func generate(transcript: Transcript, moments: [MarkedMoment]) -> SermonInsights`. `EvidenceValidator`, `InsightChunk`, and `InsightChunking` expose deterministic validation/chunking helpers; their exact declarations are in the package sources. Store adapter injection is internal for tests; the UI initializer is still `init(configuration: StoreConfiguration)`.

## Launch configuration and previews

`StoreConfiguration` is a public Sendable, Hashable enum with `.live`, `.preview`, `.uiTest(directory: URL)` and `public static func fromLaunchArguments() -> StoreConfiguration`. `CaptureEngineKind` provides `.live`, `.simulated` and the corresponding public argument reader.

- `-SermonSetPreviewData` selects an in-memory library with all eight samples, two binder cards, fixture moments, and notes. Its temporary files are used only if capture/export is invoked; bundled audio stays in the resource bundle.
- `-SermonSetUITest` selects an isolated on-disk store. An optional `-SermonSetUITestDirectory <absolute-path>` chooses the folder; otherwise the app-temporary `SermonSet-UITest` folder is reused. A new directory starts empty; an existing directory retains data across relaunch for persistence tests. Supply a unique directory for each fresh test.
- `-SermonSetSimulatedCapture` selects the tone-writing engine and grants the controller's simulated permission immediately. It never calls the microphone permission API. It works with either store configuration.
- Preview takes precedence if both preview and UI-test flags are present.

Empty capture/import titles remain empty strings when no title is supplied; the UI owns display placeholders. Edition labels are stored as `Personal` / `Sample`; a pack's title is its ISO-week ID, leaving display phrasing to the UI.

## Persistence and collection

Version 1 uses atomic JSON under Application Support/SermonSet, with recordings and session manifests in separate directories. JSON keeps this local prototype inspectable without dependencies. A mutation validates a copy, writes it atomically, and then publishes observable state. Invalid references, malformed JSON, and unsupported versions preserve the original and a recovery copy, surface `lastError`, and block writes until explicit restore/erase. The implementation currently supports version 1; it does not guess migrations for future versions.

Live files request `.completeUntilFirstUserAuthentication`. Data Protection is not verifiable on Simulator. Device backup includes app data by default; opting out sets exclusion flags on the root, recordings, and sessions directories. Export produces protected temporary JSON with private notes and audio metadata, excludes audio bytes and local audio paths, and excludes the export directory from backup. Dates use whole-second ISO-8601 precision; audio positions and ranges remain numeric with subsecond precision.

Every owned card implies library history. Keep/sample/pack/create-card retries are idempotent, and trade preview removes only the card. Sermon history, original audio, transcripts, insights, moments, and notes remain. This is a local demonstration, not a production trading backend. Edition identity and design seeds are SHA-256-derived from sermon identity. Sunday Packs use ISO weeks in UTC, choose five unique bundled samples, prefer sermons outside the library, and persist the first selection so a keep does not change that week's pack.

## Capture, recovery, and playback

A protected manifest exists before the engine starts. The live AVAudioEngine tap copies input buffers into a bounded serial writer queue, converts supported input formats to 48 kHz mono, writes 96 kbps AAC segments approximately every 30 seconds, closes each container, and checkpoints its SHA-256 checksum in the manifest. The simulated engine uses the same writer and one-second segments to exercise recovery quickly. RMS levels update at approximately 10 Hz with a 96-value history; elapsed time excludes pauses.

If `start(_:)` throws after creating its journal, cleanup cancels the ticker, stops/drains and clears the engine, and releases that session's audio ownership. An empty session with no captured audio is deleted and its journal cleared, so `start(_:)` can retry while `.failed(error)` remains visible. The journal/files are retained when segments exist or captured duration is nonzero, including buffered audio finalized by cleanup; the same controller can save with `stop()` or erase with `discard()`, and a new start remains blocked until then. A directory-removal failure is included in the error's recovery suggestion while retry remains possible. Failure callbacks carry their originating session ID, so a delayed callback from a stopped engine cannot interrupt a later recording. Engine-factory injection is internal for deterministic tests; the public capture initializer is unchanged.

Interruption, resume, route changes, media-services reset, and low-storage conditions preserve completed segments and append events. HFP provides Bluetooth microphone input; A2DP is enabled as an output profile and is not claimed to provide input. Playback pauses synchronously before capture takes the audio session. Playback uses AVAudioPlayer with rate/seek/skip, approximately 4 Hz progress, two-second store throttling, forced pause/seek checkpoints, Now Playing, and remote commands.

Stop/recovery checks completed-segment checksums, streams them into a separate final `.m4a`, hashes the immutable original, and atomically saves the sermon/history/annotations. AAC is decoded and encoded once during concatenation; temporary peak disk use includes both segments and the final original. Finalized session IDs make recovery retries idempotent. Recovery ignores unlisted partial containers; dismissed sessions retain files until explicit erase. A sudden termination may lose the unfinished live segment and queued buffers; the nominal segment interval is 30 seconds, not a measured crash-loss guarantee. Simulator snapshot recovery proves the completed-segment path, not physical crash-proof recording.

## Transcription and insights

English SpeechAnalyzer/SpeechTranscriber support and installed AssetInventory state are checked at runtime. Capability refresh never calls asset preparation. Only explicit `prepareSpeechAssets()` requests Apple's system asset installation; no installation was invoked during verification. Unavailable speech produces an observable unavailable job and retains audio. File transcription stores finalized text, times, and confidence in protected checkpoints; retry continues at the last finalized range. Transcript revisions are retained for old insight evidence. Speech permission and actual timestamp alignment still require device validation. The macOS 26.4 Apple-silicon host attempt compiled and invoked the same production adapter on `open-hands.m4a`, but English assets were `.supported`, not `.installed`, so it reported `.needsDownload` and produced no segments. Live result timestamps/confidence remain unverified; exact evidence is in `docs/REVIEW.md`.

Foundation Models availability is independent of speech and may vary on Simulator or a physical device. Each chunk uses a fresh structured `@Generable` session with a conservative UTF-8 input bound, schema/instruction overhead, a 600-token response budget, and safety reserve inside the 4,096-token context. iOS 26.4+ token-count APIs are availability guarded. Durable chunk checkpoints are bound to transcript hash, prompt/validation version (`bounded-evidence-v2`), and runtime. V1 chunks are ignored on regeneration so older sanitized output is not reused. Invalid or nonfinal citations are dropped, low-confidence evidence is flagged, and invented quoted strings are rejected before quote stripping, including nested and multiline spans. Generated and sample paraphrases remove paired or boundary quotation delimiters while retaining U+2019 and ASCII apostrophes within words (`Peter’s`, `don't`); unpaired possessives and literal internal double marks within a sentence remain intact. Existing saved insights and listener edits are not rewritten to reconstruct missing punctuation. Semantic quality still requires listener review; valid IDs alone do not establish a correct paraphrase.

Claude reported a Simulator UI run where the real on-device Foundation Models adapter generated three evidence-linked takeaways, a low-evidence flag, and an outline for the bundled “Breakfast on the Shore” transcript. That attributed observation is recorded separately from Codex's deterministic tests and the blocked host speech attempt. Physical-device AI validation remains outstanding.

If the model is unavailable before or during generation, the store uses verbatim finalized excerpts, weights source-matching marked moments higher, and records generator `Extractive — no model`. Neither adapter has a cloud fallback. Transcription and insights can be retried independently; observable jobs reset to idle on relaunch while durable checkpoints remain available for retry.

## Sample resources and verification commands

`scripts/build-samples.py` reads Claude's source fixture without modifying it, tries cached Kokoro assets in the existing read-only venv with offline flags, and falls back to installed macOS Samantha. It measures 48 kHz PCM segment lengths before encoding 64 kbps mono AAC, checks output timing/format, and writes `samples.json` plus `.m4a` files. Eight current samples occupy 6,342,936 audio bytes; their measured lengths are 88–105 seconds with the provided text and voice. They are shorter than the brief's approximate 2–3 minute content target; source content was retained. The loader marks them as samples, retains supplied rights/trust metadata, resolves evidence indexes, and records generator `Sample fixture`.

```sh
scripts/dev.sh generate
scripts/dev.sh test
scripts/dev.sh build
scripts/dev.sh run -SermonSetPreviewData -SermonSetSimulatedCapture
scripts/dev.sh run -SermonSetUITest -SermonSetSimulatedCapture
scripts/dev.sh screenshot build/sermonset-core.png
python3 scripts/build-samples.py
```

All commands honor `SIM_UDID` and `DERIVED_DATA` where applicable; defaults are the assigned Codex simulator and `build/DerivedData-core`. `SermonSetCore` is an independent scheme using `SermonSetCoreChecks`, a native test bundle compiling the same Swift Testing files against the package without UI sources. The app scheme includes the package test target and Claude's `SermonSetUITests` target. `TEST_SCHEME=SermonSet scripts/dev.sh test` selects that full scheme. Alternate AppIcon-Rubric, AppIcon-Vespers, and AppIcon-Lumen assets are enabled. Exact executed commands and evidence boundaries are recorded in `docs/REVIEW.md`.

The current core gate passes 37/37 tests and the full app build. Four regressions added for capture-start/service-date behavior cover failure before engine creation, empty engine-start cleanup/retry, delayed callbacks from the old engine, finalized/buffered AAC through save and discard, and service-date persistence with immutable creation dates. Existing quote regressions cover apostrophes, nested/boundary quotes, whole curly-quoted sentences, multiline invented quotations, generated output validation, and sample takeaway loading. These deterministic checks do not assert model availability or live transcription success on the host.

## Feature-complete core: step 1 (Voice Focus and trim)

Original/canonical audio remains unchanged. The following additions are public; all store/controller calls are MainActor. Strength is `0...1` (UI percent / 100).

```swift
struct AudioTrimWindow: Codable, Hashable, Sendable {
  init(start: TimeInterval, end: TimeInterval)
  var start, end, duration: TimeInterval
  func validate(duration: TimeInterval) throws
}
SermonStore.trimWindow(for assetID: UUID) -> AudioTrimWindow?
SermonStore.setTrimWindow(_ window: AudioTrimWindow, for assetID: UUID) throws
SermonStore.derivativeProvenance(for assetID: UUID) -> AudioDerivativeProvenance?
SermonStore.renderVoiceFocus(sermonID: UUID, strength: Double = 0.5, processMusic: Bool = false) async throws -> AudioAsset
@MainActor @Observable final class VoiceFocusController {
  init(store: SermonStore)
  var state: JobState { get }; var asset: AudioAsset? { get }
  var diagnostics: VoiceFocusDiagnostics? { get }
  func render(sermonID: UUID, strength: Double = 0.5, processMusic: Bool = false) async
}
PlaybackController.activeAssetID: UUID? { get }
PlaybackController.alignment: AudioAlignment { get } // .original, .offset(seconds: Double), .unavailable
PlaybackController.selectAudioAsset(_ assetID: UUID, levelMatched: Bool = true) throws
PlaybackController.revertToOriginal() throws
```

Provenance has `sourceAssetID`, `sourceChecksum`, `trim`, `strength`, `processMusic`, `algorithm`, `diagnostics`. Diagnostics has `clippingPercent`, `dropoutSeconds`, `appliedGainDB`, optional `inputLUFS` / `outputLUFS`, `peakDBFS`, and `musicSections: [MusicSection]` (`start`, `end` in original source seconds). Detection is heuristic and reviewable. Music bypass skips speech EQ/gate/compression; normalization and output peak protection still apply. Silence has nil LUFS. Gated K-weighted normalization targets −16 LUFS with bounded gain; limiting may lower the achieved level. A/B uses source seconds, trim bounds, and attenuates the louder track. Acoustic quality and codec intersample overshoot require physical-device validation.

## Step 2: transcript revision editing and languages

```swift
Transcript.localeIdentifier: String? // nil in older libraries/fixtures, defaults to en_US
SermonStore.editTranscriptSegment(sermonID: UUID, segmentID: UUID, text: String) throws -> Transcript
SermonStore.transcriptRevisions(for sermonID: UUID) -> [Transcript]
SermonStore.takeawaySourceChanged(_ id: UUID) -> Bool
SermonStore.outlineSourceChanged(_ id: UUID) -> Bool
SermonStore.confirmOutlineReview(_ id: UUID) throws
SermonStore.supportedTranscriptionLocales() async -> [Locale]
SermonStore.transcriptionLocale(for sermonID: UUID) -> String
SermonStore.setTranscriptionLocale(_ locale: Locale, sermonID: UUID) async throws
SermonStore.prepareSpeechAssets(locale: Locale) async throws
SpeechAnalyzerAdapter.init(localeIdentifier: String = "en_US")
FoundationModelInsightsAdapter.init(localeIdentifier: String = "en_US")
```

An actual text edit creates a new revision, preserves segment identities/timestamps and old revision, rebinds evidence, and marks only changed citations stale. UI label: “Source changed — review again”. Stale takeaways become drafts; `setTakeawayReview(..., state: .reviewed)` clears the flag. Unchanged text is idempotent. Speech checkpoints are locale-bound; unsupported languages retain private audio. Foundation Models gets the transcript locale and instructions in that language; unsupported models use extractive text in the original language. Nothing invokes an asset download without `prepareSpeechAssets`.

## Step 3: foreground venue suggestions

```swift
@MainActor @Observable final class VenueSuggestionController: NSObject {
  init()
  var state: JobState { get }; var candidates: [VenueCandidate] { get }
  func suggest(); func cancel()
}
VenueCandidate.venue(precision: LocationPrecision) -> Venue
```

Candidates expose `id`, `churchName`, optional `city/region/country`, public venue coordinates. Call `suggest()` only from a user foreground action; denial/search failure supports typed context. One fix feeds MKLocalSearch and is discarded; the controller never persists GPS. Choosing `.venue` rounds the public venue to 0.01°, `.city` strips church/coordinates, `.privateLocation` strips all location. `updateSermon` applies the same precision guard. Location never establishes recording or redistribution permission.

## Step 4: whole-library backup

```swift
SermonStore.exportLibraryBackup(passphrase: String? = nil) async throws -> URL
SermonStore.restoreLibraryBackup(from: URL, passphrase: String? = nil) async throws -> BackupRestoreResult
BackupRestoreResult.addedSermons: Int; .skippedSermons: Int
@MainActor @Observable final class BackupController {
  init(store: SermonStore)
  var state: JobState { get }; var exportedURL: URL? { get }
  var restoreResult: BackupRestoreResult? { get }
  func export(passphrase: String? = nil) async
  func restore(from: URL, passphrase: String? = nil) async
}
```

Unencrypted export is standard ZIP with stored entries (`library.json`, `audio/<asset-id>.<extension>`); it includes bundled audio used by saved samples, all notes, moments, transcripts, insights, local cards, derivative provenance and locale choices. `.ssbackup` wraps ZIP with PBKDF2-HMAC-SHA256 (210,000 rounds, random salt) and AES-GCM authentication. UI can use Files import/export or share the URL. Repeated restore merges stable identities, preserves existing original files/edits, rejects conflicting audio checksums and unsafe ZIP paths, and stages validation before saving. Identity keys are excluded (separate recovery kit). ZIP v1 is limited to <4 GB, encrypted archives to 512 MB; failures retain the current library. Unfinished capture manifests are outside the saved library.

## Step 5: offline service/offer QR verification

```swift
SermonStore.cachedServerKeys: [ServerSigningKey] { get }
SermonStore.cacheServerKeys(_ keys: [ServerSigningKey]) throws
SermonStore.verifyServiceToken(_ token: String, audience: String, now: Date = .now) throws -> ServiceGrant
ServiceTokenVerifier.init(keys: [ServerSigningKey], audience: String)
ServiceTokenVerifier.verifyService(_ token: String, now: Date = .now) throws -> ServiceGrant
ServiceTokenVerifier.verifyOffer(_ token: String, now: Date = .now) throws -> OfferGrant
```

Compact JWS verification enforces ES256, key ID/type, 64-byte P1363 signature, v1/audience, expiry and service expiry consistency. `ServiceGrant` is Codable with exact API fields: `v/aud/id/church/service/startsAt/recordingAllowed/publicSharingAllowed/reviewRequired/expiresAt/exp`. UI decodes QR to a string and supplies the configured server audience. Recorder can show the grant's recording flag; this is separate from public sharing. Unknown keys require online refresh; offline signatures cannot establish current revocation, and server publication always rechecks. OfferGrant has `v/aud/offerID/cardID/senderID/exp`.

## Steps 6–7 and 9/11: identity, sync, discovery, listening, packs, Atlas

```swift
CommunityConfiguration.init(baseURL: URL = .defaultBaseURL)
CommunityConfiguration.fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Self
CommunityConfiguration.baseURL: URL; .audience: String
@MainActor @Observable final class CommunityController {
  init(store: SermonStore, configuration: CommunityConfiguration = .fromLaunchArguments(),
       signer: (any DeviceRequestSigner)? = nil, session: URLSession = .shared)
  var state: JobState { get }; var isOffline: Bool { get }; var lastError: String? { get }
  var account: CommunityAccount? { get }
  var discover: [CommunitySermon] { get }; var churches: [CommunityChurch] { get }
  var cards: [CommunityCard] { get }; var offers: [CommunityOffer] { get }; var inbox: [InboxItem] { get }
  var atlas: [AtlasPlace] { get }; var pack: CommunityPack? { get }
  var configuration: CommunityConfiguration { get }; var sundayPack: SundayPack { get }
  func createAccount(displayName: String? = nil, avatarStyle: String = "abstract") async throws
  func updateAccount(displayName: String?, avatarStyle: String, journeyOptIn: Bool = false,
                     journeyCity: String? = nil, hidePastJourneys: Bool = false) async throws
  func deleteAccount() async throws
  func refreshAccount() async throws
  func exportRecoveryKit(passphrase: String) throws -> URL
  func importRecoveryKit(from: URL, passphrase: String) async throws
  func linkBrowser() async throws -> BrowserLinkCode // code, expiresAt
  func refreshServerKeys() async throws
  func refreshDiscover(filters: DiscoverFilters = DiscoverFilters()) async
  func refresh() async
  func foreground(); func background() // foreground refresh + 45s inbox/sync polling
  func markInboxRead(_ id: String) async throws
  func refreshChurches(query: String = "", verifiedOnly: Bool = false) async throws
  func church(_ id: String) async throws -> CommunityChurch
  func churchSermons(_ id: String) async throws -> [CommunitySermon]
  func sermon(_ id: String) async throws -> CommunitySermon
  func keep(_ id: String, source: EncounterSource = .discover) async throws
  func audioURL(sermonID: String) async throws -> AuthorizedAudio
  func refreshSundayPack() async
  func openSundayPack() async throws
  func refreshAtlas() async throws
  func journey(cardID: String) async throws -> CardJourney
}
SermonStore.localCommunityID(_ serverID: String, server: String = defaultBaseURL.absoluteString) -> UUID
SermonStore.communitySermonID(for localID: UUID) -> String?
```

All community DTOs are Codable/Hashable/Sendable and exactly match `docs/api/API.md`, using **opaque String server IDs**. Domain/store keeps UUID identities mapped by server+ID. `DiscoverFilters.init(query:type:theme:churchID:city:passage:verifiedOnly:)` has defaults for every argument. `AuthorizedAudio` has URL, expiry, audioAssetID and optional alignmentWarning. Community rights/trust come exclusively from server labels; owned community cards may include multiple instances for one sermon. Every card still implies permanent history; removing a server-owned card never removes local history or private artifacts. Failed refresh keeps the last complete cache. Community metadata has no local audio file/canonical UUID until explicitly fetched for playback. Use the community listener controller (step 12), rather than local `load`, for network audio.

Default server is one `CommunityConfiguration.defaultBaseURL` constant; `-SermonSetServer http://127.0.0.1:8788` overrides it. Request signing uses exact method/path+wire query/account/time/nonce/body hash, P1363 ECDSA; retry changes nonce and reuses a deterministic operation body key (explicit operation keys where repeated operations are meaningful). Private-library types are never serialized by the networking client.

Keychain keys are created only for explicit account work. A recoverable P-256 signing key is wrapped at rest with a Secure Enclave P-256 agreement key where available; fallback is device-only Keychain. Signing uses the unwrapped key transiently because an enclave-only signing key cannot be exported for the required recovery kit. Recovery kits use PBKDF2 + AES-GCM, include server/account/public key, and are verified with `/v1/me` before replacing the app key. Recovery files are separate from library ZIP. Tests inject `MemoryDeviceIdentity`, never read existing credentials.

Server Sunday Pack is used when reachable and complete; otherwise `sundayPack.isDemo == true` means a clearly labelled bundled sample fallback. Opening fallback stays local. Card journey suppression/consent is server-authoritative.

## Step 8: explicit reviewed publishing queue

```swift
PublishChecklist.init(musicReviewed: Bool = false, prayerRequestsReviewed: Bool = false,
                      childrenReviewed: Bool = false, privateTalkReviewed: Bool = false)
PublishSelection.init(includeReviewedText: Bool = false, audioAssetID: UUID? = nil,
                      churchID: String? = nil, service: String? = nil,
                      rightsBasis: PublicationRightsBasis = .none, serviceToken: String? = nil,
                      checklist: PublishChecklist)
SermonStore.buildPublishRequest(sermonID: UUID, selection: PublishSelection, audience: String) throws -> PublishRequest
SermonStore.publishingJobs: [PublicationJob] { get }
@MainActor @Observable final class PublishingController {
  init(store: SermonStore, community: CommunityController,
       uploader: (any PublicationUploadTransport)? = nil)
  var state: JobState { get }; var jobs: [PublicationJob] { get }
  var publications: [CommunityPublication] { get }
  func enqueue(sermonID: UUID, selection: PublishSelection, confirmed: Bool) throws -> PublicationJob
  func process(now: Date = .now) async
  func retry(_ id: UUID) async
  func refreshPublications() async throws
  func handleBackgroundSession(identifier: String, completion: @escaping @MainActor @Sendable () -> Void)
}
```

`PublicationRightsBasis` = none/churchReview/serviceQR/official. `PublicationState` uses every exact API state. Jobs have local sermon/audio IDs, immutable reviewed payload, server/account scope, server publication/sermon IDs, upload URL/task ID, attempts/retryAt/lastError. Enqueue persists confirmation; `process` sends approved content. Foreground/relaunch should call `process`; `retry` clears backoff. Background app delegate forwards the URLSession identifier/completion to `handleBackgroundSession`. Restores attach existing tasks by job UUID. Failed network retries use the same job idempotency key with a fresh signed nonce. Upload is a retryable single immutable PUT, restarted from its file after failure (the server has no byte-range resumable upload protocol). An expired capability currently requires a fresh explicitly confirmed publication job. Canonical matching/state transitions remain server-authoritative. Notes, moments, transcripts, original bytes, playback history, coordinates, and AI drafts have no fields in PublishRequest.

## Step 10: trading, offer links, nearby; step 11: reports

```swift
CommunityController.createOffer(cardID: String, kind: TradeOfferKind,
  recipientID: String? = nil, message: String? = nil, expiresAt: Date? = nil,
  operationID: UUID = UUID()) async throws -> CreatedTradeOffer // offerID, token
CommunityController.previewOffer(offerID: String, token: String? = nil) async throws -> TradeOfferPreview
CommunityController.acceptOffer(_ id: String, token: String? = nil, operationID: UUID? = nil) async throws
CommunityController.declineOffer(_ id: String, token: String? = nil, operationID: UUID? = nil) async throws
CommunityController.cancelOffer(_ id: String, operationID: UUID? = nil) async throws
CommunityController.confirmOffer(_ id: String, operationID: UUID? = nil) async throws
CommunityController.proposeSwap(_ id: String, cardID: String, token: String? = nil, operationID: UUID? = nil) async throws
CommunityController.blockAccount(_ id: String) async throws
CommunityController.unblockAccount(_ id: String) async throws
CommunityController.blockedAccounts() async throws -> [BlockedAccount]
CommunityController.report(target: ReportTarget, targetID: String, reason: ReportReason,
  timestamp: Double? = nil, details: String? = nil, operationID: UUID = UUID()) async throws -> ReportReceipt
CommunityLinkParser.init(scheme: String = AppIdentity.urlScheme, domain: String, verifier: ServiceTokenVerifier)
CommunityLinkParser.parse(_ string: String, now: Date = .now) throws -> CommunityLink
CommunityLinkParser.offerURL(token: String) throws -> URL
@MainActor @Observable final class NearbyExchangeController: NSObject {
  init(verifier: ServiceTokenVerifier)
  var state: JobState { get }; var peers: [NearbyPeer] { get }
  var receivedToken: String? { get }; var receivedGrant: OfferGrant? { get }
  func start(); func stop(); func send(token: String, to: NearbyPeer) throws; func clearReceived()
}
```

Gift/swap operations send card instance/version CAS, never local sermon data. Hold `operationID` across create/report retries; transition defaults reuse the exact operation body key. Transfers trigger full community refresh and preserve library history/private notes. Preview has offer, card and optional senderDisplayName (server hides blocked names). `CommunityLink` = `.offer(token: String, grant: OfferGrant)` or `.sermon(id: String)`. Parser accepts verified raw offer JWS, configured-scheme `://offer/<token>`, exact-domain `https://<domain>/t/<token>`, and configured-scheme `://sermon/<id>`; rejects foreign schemes/domains/extra URL fields. Nearby uses encrypted MultipeerConnectivity, transmits only bounded verified offer tokens, and requires server confirmation for ownership changes. Call stop when leaving the nearby screen.

`ReportTarget`: sermon/audio/card/account. `ReportReason`: rights/privacy/wrongAttribution/misleadingEdit/sensitiveContent/abuse. Report details are explicitly entered public moderation text, never implicitly copied from notes. Journey API remains server-suppressed unless every participant consents.

## Step 12: authorized listening and official audio choice

```swift
@MainActor @Observable final class CommunityPlaybackController {
  init(community: CommunityController)
  var state: CommunityAudioState { get } // idle/loading/ready/unavailable(reason: String)
  var sermonID: String? { get }; var audioAssetID: String? { get }
  var isPlaying: Bool { get }; var currentTime, duration: Double { get }
  var alignment: AudioAlignment { get }; var alignmentWarning: String? { get }
  var authorizationExpiresAt: Date? { get }
  func load(sermonID: String, autoplay: Bool = false, acknowledgeMomentShift: Bool = false) async
  func play(); func pause(); func seek(to: Double); func setRate(_ rate: Float); func stop()
}
PlaybackController.selectAudioAsset(_ assetID: UUID, levelMatched: Bool = true,
                                   acknowledgeMomentShift: Bool = false) throws
PlaybackController.selectOfficialAudio(communitySermonID: String, community: CommunityController,
                                      acknowledgeMomentShift: Bool) async throws
PlaybackController.play(moment: MarkedMoment) throws
SermonStore.addMoment(sermonID: UUID, audioAssetID: UUID, time: TimeInterval, note: String?) throws -> MarkedMoment
SermonStore.addNote(sermonID: UUID, audioAssetID: UUID, text: String, time: TimeInterval?) throws -> PersonalNote
```

Remote playback gets a rights-checked short-lived URL and checks cached revocation during playback. An official replacement requires “Your moments may shift” acknowledgement; alignment is `.unavailable` because the server provides no offset. The local original/canonical asset and old personal anchors remain intact. Use the explicit audioAssetID note/moment overloads for a switched source. For community streams, the asset UUID is `localCommunityID(audioAssetID, server: configuration.audience)` once duration is ready; keeps have persistent history even if audio is later unavailable. `play(moment:)` selects that moment's local source. Remote stream sources without local files cannot be replayed offline.

## Steps 13–14: share links and brand settings

```swift
CommunityController.createShare(sermonID: String, renderedPNG: URL,
                                operationID: UUID = UUID()) async throws -> URL
AppIdentity.displayName: String { get }; AppIdentity.urlScheme: String { get }
```

Share takes Claude's rendered **public card PNG** and an existing community sermon ID, validates PNG/size/checksum, uploads to a capability URL, and returns the share-page URL after success. A private sermon must first go through explicit publishing. Hold operationID across share retries.

`project.yml` has one `APP_BRAND` setting; processed Info.plist derives display name, URL scheme (lowercase), and permission-copy brand words from it. Core reads processed Bundle values via AppIdentity; local storage identifiers remain the stable codename. iOS UI's own AppBrand is Claude-owned and should read these values. Support plist includes foreground location, camera, encrypted nearby Bonjour service, and local-development transport support.

## UI-request follow-up (Sower, AAC duration, service context)

Authoritative owner brand decision is `docs/build/BRAND.md`: APP_BRAND is now **Sower**, bundle ID `com.gazhenko.sower`, scheme `sower`, default API host `https://sower.gazhenko.dev`. Both `-SowerServer` and legacy `-SermonSetServer` work. `CommunityConfiguration.current.audience` reads launch configuration.

```swift
SermonStore.playableDuration(for asset: AudioAsset) -> TimeInterval
CaptureDraft.init(title: String? = nil, preacher: String? = nil, churchName: String? = nil,
                  city: String? = nil, serviceToken: String? = nil)
CaptureDraft.serviceToken: String?
SermonStore.serviceToken(for sermonID: UUID) -> String?
SermonStore.setServiceToken(_ token: String?, for sermonID: UUID) throws
```

Playable duration uses decoded frames for local files. Trim validation accepts at most 0.1 s of AAC end padding; saved/default windows clamp to the decoded end, and derivatives record actual offsets. Publishing still requires an explicitly saved trim. Service token travels with the capture recovery manifest into saved sermon context and ZIP backup; it conveys contextual permission only and is reverified at publishing. It is never treated as blanket clearance.

## UI compatibility signatures (CORE-REQUESTS §6)

Core now also provides `OfferTicket` / `OfferPreview`, and these aliases:

```swift
CommunityController.sendReport(targetType: String, targetID: String, reason: String, timestamp: Double?, details: String?) async throws
CommunityController.createOffer(cardID: String, kind: String, message: String?, recipientID: String?) async throws -> OfferTicket
CommunityController.previewOffer(id: String?, token: String) async throws -> OfferPreview
CommunityController.proposeSwap(_ id: String, token: String?, cardID: String) async throws
CommunityController.confirmSwap(_ id: String) async throws
CommunityController.block(accountID: String) async throws
CommunityController.unblock(accountID: String) async throws
CommunityController.blockedAccountIDs: [String] { get }
CommunityController.refreshBlocks() async throws
CommunityController.communityCard(forLocalCard id: UUID) -> CommunityCard?
CommunityController.createShareLink(sermonID: String, cardImagePNG: Data) async throws -> URL
PlaybackController.playCommunity(sermonID: String, localID: UUID,
                                community: CommunityController, from: TimeInterval = 0) async throws
PlaybackController.officialAudioAvailable: Bool { get }
PlaybackController.usingOfficialAudio: Bool { get }
PlaybackController.useOfficialAudio(_ on: Bool) async throws
@MainActor @Observable final class NearbyExchange: NSObject {
  enum State { case idle, searching, connected(peerName: String), sent, received(token: String), failed(String) }
  var state: State { get }
  init(displayName: String)
  func offer(token: String); func receive(); func stop()
}
```

`playCommunity` streams through the shared player/mini player/lock screen, refreshes expiring authorization, retains source asset UUID anchors, and surfaces rights changes. `useOfficialAudio(true)` is the UI's explicit acknowledged choice; UI must show the warning before invoking it. Automatic URL refresh refuses a different master. NearbyExchange uses service `sower-card`, transports only a bounded offer token, and leaves cryptographic verification to `previewOffer`; nearby receipt never itself accepts a trade. Discovery uses an ephemeral listener label rather than publishing account names. The lower-level NearbyExchangeController remains available for explicit peer selection with immediate offline verification.

Claude should remove the temporary `sendReport` shim in `SermonSet/Features/Community/PendingCoreAPI.swift` now that the core method exists (core does not edit UI-owned files).

Publishing now exposes `PublishingController.cancel(_ id: UUID) throws` and `PublicationJob.isCancelled: Bool?`. Cancelling works before submission or during raw upload, stops that task, and preserves all local audio. Submitted review/published content requires the server's removal/report flow; cancellation never fabricates a server rejection state. Cancelled jobs are not retried.

Final hardening: queue backs off/retries transient failures automatically while the app runs and polls submitted review states; relaunch/foreground `process()` reattaches tasks. Create-offer UI alias also accepts optional `operationID: UUID? = nil`; default is stable for the same card/version/message. Pass a new operation UUID to intentionally create another identical offer. `CommunityController.tradeHistory(for cardID: String) -> [CommunityOffer]` exposes only this account's visible offer history; opt-in coarse cross-owner history is `journey(cardID:)`. Locally cached official masters require unexpired server authorization and reject known revocation/replacement; originals remain available. Reverting when no personal original exists returns an explicit unavailable error. Backup restores remote asset metadata without implying offline audio bytes exist.

## Required publishing details (CORE-REQUESTS §7, 2026-10-05)

`SermonStore.buildPublishRequest(sermonID:selection:audience:)` now requires a nonblank title, preacher, and passage plus an explicitly chosen `Sermon.sermonType`. Missing optional strings, empty strings, and strings containing only whitespace/newlines count as missing. It throws `SermonSetError(title: "Public details need review", message: "Add the missing fields before publishing: ….")`, listing only the missing fields in title, preacher, passage, kind order. For example, an otherwise complete sermon without a kind reports `Add the missing fields before publishing: kind.` All four missing reports `Add the missing fields before publishing: title, preacher, passage, kind.`

The request uses the chosen kind's raw value with no fallback. Preacher and passage retain their existing trimming behavior; validation does not edit the local sermon. The method signature is unchanged. Swift Testing covers each missing field individually, all missing fields with nil/empty/whitespace values, and successful requests preserving each of the eight supported kinds (including explicitly chosen hope). Existing unit and local-server publishing fixtures now choose wisdom explicitly. Exact Simulator commands and results are recorded in `docs/REVIEW.md`.

## Framework callback isolation (CORE-REQUESTS §8, 2026-10-05)

`LiveCaptureEngine.resume()` installs the tap returned by `nonisolated static makeTap(writer:)`. The factory forms an explicit `@Sendable` closure, so AVFAudio can invoke it on its realtime queue without inheriting the engine's main-actor isolation. It still calls `SegmentWriter.append` directly: buffers are copied before the tap returns, and conversion/encoding/file writes remain on the writer's serial queue. No main-actor hop or file I/O was added to the realtime callback.

Every changed callback call site is listed below (19 total). All outer closures are explicitly `@Sendable`; the tap factory is also `nonisolated`. Callbacks that update controller state retain their explicit `Task { @MainActor ... }` hops. Speech authorization only resumes its checked continuation; the suspended main-actor transcription method resumes on its actor. Several sites already accepted a Sendable callback or were outside an actor; their explicit annotations make the audited boundary visible without changing behavior.

| File / enclosing method | Changed call site |
| --- | --- |
| `CaptureEngines.swift` / `LiveCaptureEngine.resume`, `makeTap` | `AVAudioNode.installTap` block creation moved into the nonisolated factory. |
| `CaptureEngines.swift` / `SegmentWriter.write` | `AVAudioConverter.convert` input block. |
| `CaptureController.swift` / `start` | Engine `onFailure` callback, invoked from the writer queue. |
| `CaptureController.swift` / `observeAudioSession` | NotificationCenter interruption observer, `queue: nil`. |
| `CaptureController.swift` / `observeAudioSession` | NotificationCenter route-change observer, `queue: nil`. |
| `CaptureController.swift` / `observeAudioSession` | NotificationCenter media-services-reset observer, `queue: nil`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `playCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `pauseCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `togglePlayPauseCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `skipForwardCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `skipBackwardCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `changePlaybackPositionCommand.addTarget`. |
| `PlaybackController.swift` / `configureRemoteCommands` | `changePlaybackRateCommand.addTarget`. |
| `PlaybackController.swift` / `observeSession` | NotificationCenter interruption observer, `queue: nil`. |
| `PlaybackController.swift` / `observeSession` | NotificationCenter route-change observer, `queue: nil`. |
| `PlaybackController.swift` / `observeSession` | NotificationCenter media-services-reset observer, `queue: nil`. |
| `SpeechAdapter.swift` / `SpeechAnalyzerAdapter.transcribe` | `SFSpeechRecognizer.requestAuthorization` callback. |
| `Publishing.swift` / `BackgroundPublicationUploader.init` | `UploadDelegate.completion` callback invoked by URLSession's delegate queue. |
| `Publishing.swift` / `BackgroundPublicationUploader.init` | `UploadDelegate.finished` callback invoked by URLSession's delegate queue. |

The audit covered every Swift source file in SermonSetCore, including untracked files present at task start. Existing MultipeerConnectivity entry points in `NearbyExchange.swift` and `NearbyUIBridge.swift`, CoreLocation entry points in `VenueSuggestion.swift`, and `PlaybackController.audioPlayerDidFinishPlaying` are already `nonisolated` and hop to the main actor before touching controller state. `UploadDelegate` is a non-actor, Sendable class; its URLSession delegate methods call Sendable bridges. They need no additional isolation change. URLSession data/download/upload and MapKit searches use async APIs. Speech recognition consumes `SpeechTranscriber.results` inside an explicit main-actor Task rather than a legacy recognition handler. Microphone permission uses the async `AVAudioApplication.requestRecordPermission` API. Writer dispatch closures are formed in a non-actor class and use its existing Sendable/locked queue boundary. There are no other taps, player-node scheduling completions, Network.framework callbacks, AVAssetExportSession callbacks, Timer/DispatchSource callbacks, or timers on other queues in this package. Periodic work uses actor-inheriting Tasks and `Task.sleep`; synchronous collection/persistence closures and explicitly main-actor app callbacks remain unchanged.

`CallbackIsolationTests.liveTapWritesFromBackgroundQueue` creates the exact production tap on the main actor, invokes it from a dedicated background dispatch queue, reuses/zeros the input buffer, flushes the production writer, and verifies saved AAC contains the original nonzero audio with matching manifest duration/checksum. Its 48 kHz mono case exercises direct append; its 44.1 kHz stereo case also invokes the converter input block, allowing the existing converter latency. Existing capture interruption/resume/route/reset and playback tests now post notifications from a background queue and verify their main-actor effects.

`scripts/dev.sh test` passed (59 tests, 12 suites); the requested unsigned device app build passed. Exact commands, logs, initial harness failures, and outcomes are in `docs/REVIEW.md`. The available iOS 26.5 Simulator / Swift 6.3.3 harness did not reproduce the reported iOS 27 physical-device runtime trap before the explicit annotations; passing tests and a device build do not establish physical-iPhone recording validation. No commits, dependency installs, or edits to `SermonSet/`, `web/`, `site/`, or `server/` were made.

## On-device summary — CORE-REQUESTS §9 (2026-10-05)

The UI contract is available in `SermonSetCore`. All store access is `@MainActor`:

```swift
public var summarizeAfterRecording: Bool { get set } // persisted; older libraries default true
public func processRecording(sermonID: UUID) async
public func regenerateSummary(sermonID: UUID) async
public func editSummary(sermonID: UUID, bigIdea: String, text: String, reflectionQuestion: String?) throws
public func setSummaryReview(sermonID: UUID, state: ReviewState) throws
public func useSummaryOnCard(sermonID: UUID) throws
```

`SummarySentence: Codable, Hashable, Sendable, Identifiable` exposes `id: UUID`, `text: String`, `evidence: EvidenceRange?`, and `isLowEvidence: Bool`. `SermonSummary: Codable, Hashable, Sendable` exposes `bigIdea: String`, `sentences: [SummarySentence]`, `reflectionQuestion: String?`, `reviewState: ReviewState`, and `isEdited: Bool`. Both have public initializers. `Takeaway.isEdited: Bool` also tracks listener rewrites independently of review state and defaults false when decoding older takeaways. `SermonInsights.summary: SermonSummary?` and `.summaryUnavailableReason: String?` decode as nil in older libraries. `ProcessingJobs.summary: JobState` defaults to `.idle`, including decoding older job values. Use `store.jobs(for: id).summary` to display summary progress separately from takeaways.

After a successful `CaptureController.stop()`, the UI checks `store.summarizeAfterRecording` and calls `await store.processRecording(sermonID: sermon.id)` while foregrounded. The method first transcribes if no current transcript exists, then generates takeaways and summary. It retains an independent per-sermon task, deduplicates concurrent calls, and awaits completion without inheriting the caller's cancellation; leaving the screen does not cancel it. It records a durable pending marker before starting. Live stores resume pending work on initialization and `UIApplication.didBecomeActiveNotification`. Speech segments and validated chunk notes are protected, atomic checkpoints under the store's `Jobs` directory. Completed unavailable-summary results are terminal and expose their reason; interrupted/failed pipelines remain pending for foreground/relaunch retry. No audio is removed or replaced by processing.

`regenerateSummary` changes only summary fields and reuses cached notes when transcript content/locale, prompt version, and generator runtime match. It preserves takeaways, outline, suggested title, and their provenance. Accepted/rejected or edited summaries are retained on regeneration; full `generateInsights` also preserves accepted/rejected takeaways and the latest listener edits made during inference. `editSummary` trims fields, splits body text with `NLTokenizer(unit: .sentence)`, clears every sentence's evidence, and sets `.reviewed`/`isEdited = true`. Empty big idea/body and missing library/summary throw listener-readable `SermonSetError`. Review changes persist without altering evidence. After a fresh transcription with new segment IDs, retained accepted summaries/takeaways keep their exact evidence in the saved earlier revision and are flagged low evidence for the current revision; acceptance does not set `isEdited`. Summary-only regeneration uses the current transcript while keeping existing takeaway/outline citations valid against their own saved source revision. `useSummaryOnCard` copies `bigIdea` to `Sermon.summary` and `reflectionQuestion` to `Sermon.reflectionPrompt`. It does not publish anything. Transcript corrections rebase summary evidence and mark affected summary text as draft/low evidence.

### Info.plist and background configuration owned by the UI

Add this exact wildcard to the app's existing `BGTaskSchedulerPermittedIdentifiers` array, and add `processing` to its existing `UIBackgroundModes` array (retain the recording/playback `audio` mode):

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.gazhenko.sower.process.*</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>processing</string>
</array>
```

In Xcode this is Background Modes → Background processing, alongside existing audio. The core does not modify `project.yml` or `SermonSet/Support/Info.plist`. No `fetch` mode, remote notifications, network permission, account, or new privacy usage string is needed for summary generation. Existing speech and microphone permission strings still apply to transcription/recording. The implementation requests default continued-processing resources, without requesting `.gpu`; it does not require the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement. Foundation Models manages its own inference resources; sustained model inference while locked/backgrounded requires physical-device verification.

The core checks the keys before calling the scheduler. While the live app is active it registers a unique `com.gazhenko.sower.process.<UUID>` handler and submits `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` with `.fail` (immediate eligibility), title **Summarizing your sermon**, and subtitles **Transcribing on your iPhone** / **Drafting the summary**. A granted `BGContinuedProcessingTask` uses `progress.totalUnitCount = 1000`, increasing completed counts, `updateTitle(_:subtitle:)`, an expiration handler that cancels the store task, and `setTaskCompleted(success:)`. Scheduler and expiration callbacks are explicit Sendable bridges to the main actor. Registrations use fresh identifiers exactly once; the SDK exempts continued-processing handlers from before-launch registration. Test/preview stores do not register system tasks. macOS and Catalyst keep the same foreground/checkpoint pipeline without this iOS-only scheduler.

Runtime eligibility is conditional. Missing keys, a background-only invocation, denied background execution, resource contention, expiration, or process termination cannot guarantee continued execution. A rejected request continues foreground work; protected checkpoints and the pending marker allow resume after a return/relaunch. `.fail` avoids a queued system activity starting after foreground work has already completed. The scheduler does not promise relaunch after force quit. No physical-device background/lock-screen inference success is claimed by compilation or Simulator fixtures.

### Prompt and evidence design

Prompt version is **bounded-evidence-summary-v3**. Production generation uses only `SystemLanguageModel(guardrails: .permissiveContentTransformations)` and fresh `LanguageModelSession`s; there is no remote model or network path. On-device availability and transcript locale are checked explicitly. Disabled Apple Intelligence, unsupported hardware/language, or unready assets leave `summary` nil with a readable `summaryUnavailableReason`. The extractive fallback still supplies takeaways and never synthesizes a summary. All eight bundled sample sermons have explicit hand-written three-sentence summaries with fixture evidence, solely for previews/tours.

The existing chunk pass generates at most three takeaways/chapters plus two or three short grounded notes with source segment indexes. Prompts treat transcripts/notes as untrusted data, prohibit following embedded instructions, invented words/names/speakers/scripture, reconstructed speech and quotation marks, and call the speaker **the preacher**. Notes and summary sentences use plain, warm, concise third person. Reduce output has a one-sentence big idea of at most 25 words (no “This sermon is about”), three to six sentences in source order, and an optional open listener question. Notes are encoded as JSON data with stable IDs; output cites those IDs, never invented timestamps.

Each stage reserves instructions, schema, response budget, and framing within `model.contextSize`, with a conservative UTF-8 input cap of 1600 bytes. iOS/macOS 26.4+ use the SDK's `tokenCount(for:)` for instructions, schema, and prompts; 26.0–26.3 use conservative UTF-8 sizing. Oversized notes are reduced in bounded groups, repeating up to twelve levels and requiring the data to shrink. Intermediate notes preserve the union of their cited original segment IDs. Final citations resolve back to exact `EvidenceRange`s; invalid/nonfinal/wrong-revision citations, invented quoted speech, absent scripture citations, and detected unsupported proper names are rejected. Low-confidence source segments flag sentences as low evidence. Generated output remains `.draft` until reviewed or rewritten. Structural checks establish source linkage; semantic faithfulness and named-entity detection remain model-dependent and need listening review.

Chunk guardrail/refusal/context-window errors save an empty chunk and continue through the remaining sermon. A failed final reduction yields no summary plus a readable reason, preserving the transcript, takeaways, and note checkpoints. Cancellation propagates so the pipeline can resume rather than presenting a partial result as complete. Cached chunk notes and hierarchical reduction checkpoints are invalidated by transcript hash, locale, prompt version, or runtime changes.

## Automatic speech asset preparation — CORE-REQUESTS §10 (2026-10-05)

`processRecording(sermonID:)` now prepares speech assets when the recording's transcription adapter reports `.needsDownload`. It uses the same selected-language adapter for preparation and transcription, sets `jobs(for: id).transcription = .running(progress: nil)` throughout preparation, then rechecks availability and continues through transcription, takeaways, and summary. Already-ready assets and recordings with a current transcript skip preparation. Downloads use the existing Apple system-asset installation API; audio and transcript content stay on the phone.

No public API signatures changed. Manual `transcribe(sermonID:)` still reports the existing unavailable reason when assets need downloading; explicit `prepareSpeechAssets()` remains available. Unsupported locales retain their readable `.unavailable` reason, and installation errors use the existing `.failed(message:)` reporting. Failed automatic runs retain their pending marker for retry and preserve the original audio and checkpoints. Cancellation uses the existing idle/pending recovery behavior.

`RecordingSpeechAssetsTests` uses a deterministic adapter to observe indeterminate progress across an asynchronous preparation suspension, complete a summary, retain a selected transcript locale, fail and retry a download, reject unsupported/unready post-installation states, skip unnecessary preparation, and verify manual preparation remains explicit. Test results and exact commands are recorded in `docs/REVIEW.md`. Real Apple asset downloads on a fresh physical iPhone remain unvalidated here.

## Sermon Notes — CORE-REQUESTS §11 (2026-10-07)

The section 11 public contract is implemented in `Packages/SermonSetCore`. This supersedes §9’s live summary model/reducer; §9–10’s task ownership, speech preparation, and background configuration remain applicable. `SermonInsights.notes: SermonNotes?` and `notesUnavailableReason: String?` are optional Codable fields; older libraries still decode their original `summary` without manufacturing notes. `SermonNotes`, `SermonPoint`, and `KeyPhrase` expose exactly the requested property names/types and public initializers. The legacy summary model/properties and `regenerateSummary`, `editSummary`, `setSummaryReview`, `useSummaryOnCard`, and adapter `generateSummary` remain source-compatible and are deprecated.

UI entry points (all main actor):

```swift
public func processRecording(sermonID: UUID) async
public func regenerateNotes(sermonID: UUID) async
public func editNotes(sermonID: UUID, notes: SermonNotes) throws
public func setNotesReview(sermonID: UUID, state: ReviewState) throws
public func useNotesOnCard(sermonID: UUID) throws
public internal(set) var notesStageDetail: String?
```

Use `jobs(for: id).summary` for the notes job. Retaining a legacy summary does not mark an unavailable notes generation as done. `notesStageDetail` is observable, reports exactly **Reading the sermon**, **Finding the points**, **Writing the notes**, and clears when inference finishes. `editNotes` stores the whole supplied value, retaining point IDs, evidence, phrases and times, and sets `isEdited = true` / `.reviewed`. Empty big idea/point text, invalid times, missing artifacts, and invalid persisted references throw listener-readable `SermonSetError`. `useNotesOnCard` copies `bigIdea` to `Sermon.summary` and the first question to `Sermon.reflectionPrompt`.

Notes-only regeneration changes only notes and current transcript/prompt provenance, retaining takeaways, outline, suggested title, and legacy summary. Accepted, rejected, or edited notes are retained. Full `generateInsights` also preserves them, and both paths re-read the latest saved artifacts after inference so edits made while waiting survive. Transcript corrections rebase evidence to the corrected revision, mark affected notes draft, and remove an exact phrase if it no longer occurs in its corrected source. Accepted notes retained across a fresh transcription keep citations to the saved original revision.

The injectable public engine contract is:

```swift
@MainActor public protocol SermonNotesEngine: Sendable {
    func capability(localeIdentifier: String) -> CapabilityStatus
    func generate(
        transcript: Transcript, checkpointDirectory: URL,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onStage: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> NotesGenerationResult
}
public struct NotesGenerationResult: Sendable {
    public var notes: SermonNotes?
    public var unavailableReason: String?
}
public init(configuration: StoreConfiguration,
            notesEngine: any SermonNotesEngine = FoundationModelSermonNotesEngine())
```

`FoundationModelSermonNotesEngine` uses `SystemLanguageModel(guardrails: .permissiveContentTransformations)` and a fresh `LanguageModelSession` for every section/retry and reduction. There is no network inference. The iOS 26.5 installed SDK interface was read directly at `FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`: `tokenCount(for: Prompt/Instructions/GenerationSchema)` is available from iOS/macOS 26.4, `contextSize` from 26.0 with back deployment, and `GenerationOptions(temperature:maximumResponseTokens:)` is the real SDK API. Notes require 26.4 for token-counted sections; earlier systems retain transcription/takeaways and show a notes availability reason.

The notes prompt/checkpoint version is **sermon-notes-v1**. Cleaning joins final segments into timed sentences, drops um/uh/erm, collapses word/phrase stutters, and ends unpunctuated sentences at a segment boundary after about 40 words (exceptionally long single segments are also bounded). Cues cover the requested ordinal point/thing/truth/principle/key/lesson/step/idea forms, point number one/two/etc., number one/two/etc., secondly, thirdly, and finally, lastly; cues need six sentences between them. At least two ascending cues set `pointsAnnounced`. Opening welcome/announcements and closing prayer are tagged as non-points.

Sections split at cues and role boundaries, targeting **2,200 input tokens**, reduced when necessary to reserve instructions, schema, response, and margin inside `contextSize`. The requested map/reduce tone prompts are used verbatim with only language/schema mechanics added. Map output carries integer sentence citations and an exact phrase's sentence number. Reduction receives plain section notes with times/roles/headings, with section references only in integer output fields. It requires exactly the announced count or two to four unannounced points. Announced stretches each retain a point, including the middle, even when the model repeats or omits citations; every point gets original section evidence and audio start, and output is sorted by start. If the complete reduction exceeds context, optional illustration/application detail is removed while keeping every section; a still-oversized input returns an unavailable reason rather than losing the middle.

All prose rejects leaked `[12]`, segment(s) numbers, section numbers, `c0-n2`, `citing`, and `index` machinery, with one fresh retry at higher temperature (0.2 → 0.7). Invalid required fields fail the notes result instead of silently dropping points. Optional unsupported scripture/phrases are omitted; phrases must match case/punctuation/filler-normalized original words and are stored as exact source text, never quoted paraphrases. Scripture requires the named book and explicit reference in the supporting section. Guardrail/refusal/context errors split a section in half once; failing halves are recorded as skipped and other sections continue. Model unavailability or failed reduction leaves notes nil with a readable reason, preserving takeaways/transcript/audio.

Protected, atomic `Jobs/notes-<transcriptID>.json` checkpoints reuse successful mapped sections only when transcript hash (including locale), prompt version and runtime match. Skipped sections are retried on later runs. The existing `processRecording` task ownership, automatic speech asset preparation, foreground/relaunch resume, and continued-processing background configuration from §9–10 remain in force. Live takeaway generation retains its existing evidence/chunk behavior but no longer runs the legacy summary reducer; the notes engine runs next. Legacy deterministic summary adapters/tests remain supported separately.

DEBUG evaluation hooks are core-owned and need no UI shim:

- `-SermonSetNotesTrace` writes protected `Documents/NotesTrace/<sermonID>-<timestamp>.json` containing cleaned sentences, cues, sections, mapped/skipped notes, raw map/reduce attempts, exact reduce prompt, final notes/reason, retries, and stage/section/total timings. These files contain private transcript material and stay local.
- `-SermonSetRegenerateNotes <UUID|latest>` runs notes regeneration on live-store launch after pending processing resumes. `latest` chooses the newest non-sample library recording with a transcript. Accepted/edited notes remain protected by the normal regeneration rules.

All eight samples include three hand-written notes points, exact phrases from their bundled transcripts, passage, one weekly action, two listener questions and fixture engine provenance. These are preview fixtures, not an unavailable-model fallback. `NotesTests` covers cleaning/cues, token-sized sections, exact leaked strings, source phrases/scripture, point ordering/count/evidence fallback, retry/split/skip behavior, checkpoint reuse/cancellation/invalidation, legacy decoding, samples, and store edit/review/card/concurrent-edit behavior. Commands and final outcomes are recorded in `docs/REVIEW.md`. Real-model notes quality, locked/background inference, and trace extraction on the owner's physical iPhone still require device evaluation.

## Optional Qwen notes engine — CORE-REQUESTS §12 (2026-10-07)

Implemented in `Packages/SermonSetLocalModel`, library product **SermonSetLocalModel**. The owner-approved MLX exception is confined to this package. `Packages/SermonSetCore/Package.swift` remains unchanged and has no package dependencies. Existing Apple injection via `SermonStore(configuration:notesEngine:)` remains available; the store's public `notesEngine` property now holds the persisted `NotesEngineChoice` (`.appleIntelligence` default, `.openSource`). Older documents decode with the Apple default.

### Exact project.yml addition for Claude

Merge this local package entry into the existing `packages` mapping, and the dependency into `targets.SermonSet.dependencies`:

```yaml
packages:
  SermonSetLocalModel:
    path: Packages/SermonSetLocalModel

targets:
  SermonSet:
    dependencies:
      - package: SermonSetLocalModel
        product: SermonSetLocalModel
```

The upstream declaration is already owned by the new package's `Package.swift`:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3")
// Target products from that package:
.product(name: "MLXLLM", package: "mlx-swift-lm")
.product(name: "MLXLMCommon", package: "mlx-swift-lm")
```

Its `Package.resolved` pins the complete transitive graph, including `mlx-swift` 0.31.6 and `swift-transformers` 1.2.1. These are upstream MLX runtime/tokenizer dependencies, not dependencies of SermonSetCore. Resolution preceded engine implementation. The resolved release is commit `25b00d4e22e61ec9c41efda47990cd2084ec87ff`; `Libraries/MLXLLM/Models/Qwen35.swift` exists, and `LLMModelFactory.swift` registers `qwen3_5`, `qwen3_5_text`, and `qwen3_5_moe`. Qwen35's text loader filters vision weights in `sanitize(weights:)`. API source: [pinned MLX release](https://github.com/ml-explore/mlx-swift-lm/tree/2.31.3).

### App wiring and owner-controlled device configuration

Create one long-lived main-actor manager, import the new module, and supply the engine at store construction so resumed processing sees it immediately:

```swift
import SermonSetCore
import SermonSetLocalModel

let localModel = LocalModelManager()
let store = SermonStore(
    configuration: StoreConfiguration.fromLaunchArguments(),
    openSourceNotesEngine: LocalQwenNotesEngine(manager: localModel)
)
// Invoke once from the app's startup task; also installs the engine on an
// already-created store and processes the DEBUG download/comparison arguments.
await LocalModelDebug.configure(store: store, manager: localModel)

store.notesEngine = .openSource  // persisted; Apple remains the default
```

Keep the same manager alive across Settings, notes processing, and app-delegate background callbacks. Settings can bind `store.notesEngine` and `localModel.allowCellular`, read `localModel.state`/`isOnCellular`, and call `start()`, `pause()`, `cancel()`, or `delete()`. `cancel()` discards the current partial transfer and resume data while retaining verified files; `delete()` removes the whole model. Selecting `.openSource` while not `.ready` uses the injected Apple engine. Saved notes retain `Apple Intelligence (on-device)` provenance, and `notesUnavailableReason` explains that Qwen was not ready; if Apple is unavailable too, notes stay nil with both reasons. A downloaded model that fails memory/inference/validation checks reports its Qwen failure, without inventing notes or silently changing the selected setting.

For iOS background download relaunch, forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to:

```swift
localModel.handleBackgroundEvents(identifier: identifier) {
    completionHandler()
}
```

The callback API is main-actor/Sendable; use a main-actor delegate bridge under the app's existing Swift concurrency settings. The identifier is `LocalModelManager.backgroundSessionIdentifier` (`com.gazhenko.sower.qwen35.model-download`). Background URLSession downloads require this lifecycle forwarding, not a new Background Modes checkbox or a network privacy usage string. The manager delays the completion callback while installing/verifying a delivered file. No audio or transcript is passed to the downloader. The existing §9 continued-processing setup remains separate; sustained MLX GPU inference while locked/backgrounded is unvalidated.

For the large model, Claude should enable **Increased Memory Limit** and add the optional app entitlement:

```xml
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
```

The package can compile without it, and inference always checks actual app headroom rather than assuming the entitlement works. Apple documents that this entitlement only increases memory on supported devices and requires checking `os_proc_available_memory()`; see [Apple entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit). **Free provisioning grant is not verified:** no credentials or signed profiles were accessed. Apple's current [iOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios) lists *Increased Debugging Memory Limit* for paid programs only, which does not establish free eligibility for the distinct kernel entitlement above. A Personal Team build without the optional entitlement is possible, but adequate Qwen memory and a grant of increased memory must be checked on the owner's signed device. No paid account requirement is asserted for all uses of this package. Extended virtual addressing and background GPU entitlements are not requested here.

### Model storage and inference

`LocalModelConfiguration.repository` is `mlx-community/Qwen3.5-4B-MLX-4bit`; `.revision` is pinned to `32f3e8ecf65426fc3306969496342d504bfa13f3`. The repository reports Apache 2.0 in its [model metadata](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit). The explicit text-inference file manifest totals **3,054,404,243 bytes** (about 3.05 GB), including the mixed text/vision safetensors file. It fetches config, tokenizer config/JSON, chat template, weight index, and weights; image/video preprocessing files are unnecessary. The weight and tokenizer SHA-256 values come from the pinned repository metadata and are verified before installation. All files require the expected size. Changing the repo/revision and manifest in this one configuration file permits a later slimmer mirror.

Model storage is `Application Support/SermonSet/LocalModels/Qwen35-<revision>`, excluded from iCloud/device backup. iOS files use protection until first unlock, allowing background transfers after unlock. `NWPathMonitor` observes cellular use; cellular downloads default off. URLRequest independently prohibits cellular transfer unless allowed. The setting persists; changing it restarts only the current file when opaque resume data retains the old request policy. Before downloading, the manager reserves remaining file bytes plus the largest temporary download and 512 MiB (about 6.63 GB for a fresh full download). Insufficient space yields a readable failure. URLSession resume data, transfer identity, verified files, and the retained Inbox file survive normal relaunch. Restored tasks are matched by durable identity; stale completions after cancel/delete are discarded. Actual OS scheduling/resume and network transitions still need physical-device verification; force quit does not guarantee background execution.

The engine uses the verified local directory with `LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory:))`. Both tokenizer and weights resolve locally. The real 2.31.3 API used is `ModelContainer.prepare(input:)`, `generate(input:parameters:)`, and `encode(_:)`; `UserInput(chat:additionalContext:)` sets `enable_thinking: false`. `GenerateParameters` uses temperature **0.2**, maximum output tokens, and a 256-token prefill step. No VLM product or network inference is used.

The shared `NotesPreparation` supplies the same cleaning, timed numbered sentences, ordinal cues, role boundaries, and announced count as Apple. A whole-transcript pass runs when the actual chat-template token count, 2,400 response tokens, and a 128-token margin fit **16,384 tokens**. Larger sermons use cue/role-aware **6,000-token** sections and the existing section notes/reduction DTOs. Successful sections have protected atomic checkpoints keyed by full transcript content, model revision, and prompt version `qwen35-sermon-notes-v1`. Reduction preserves all sections and strips optional illustration/application detail if necessary; an input still exceeding the context returns a reason with completed sections saved.

Prompts contain the JSON shapes and §11 tone/field rules. `NotesJSON.decode` extracts one JSON object from prose/code fences and repairs trailing commas outside strings without changing literal quoted text. Parse/type failures get one fresh request at temperature 0.2. Every parsed result passes the same public `NotesValidation` as Apple: machinery rejection/diagnostic stripping, names/quotation grounding, word limits, supported scripture, exact source key phrases, sentence counts, weekly verbs, two listener questions, point order, and exact announced count. Whole-transcript sentence starts are converted to original evidence ranges by `NotesValidation.transcriptNotes`; invalid starts, duplicated starts, and incorrect announced stretches fail the result. No required point is silently dropped. Optional unsupported scripture/phrases are omitted. Notes retain `Qwen 3.5 4B (on-device)` provenance and draft review state.

Before loading on iOS, `os_proc_available_memory()` must exceed downloaded model bytes plus 1.5 GiB of working headroom (about 4.67 GB); each generation also requires 512 MiB headroom. MLX buffer cache is capped at 20 MiB during a run and restored afterward. A single inference run is admitted at a time; model references and buffer cache are released after success, failure, and cancellation. These snapshot gates reduce risk but cannot guarantee against system jetsam; actual peak memory and model quality require device evaluation. Progress reports **Loading the model**, **Reading the sermon**, and **Writing the notes** through existing notes stage/job callbacks.

### DEBUG comparison

`LocalModelDebug.configure` handles `-SermonSetDownloadLocalModel` and `-SermonSetCompareNotes <UUID|latest>`. `latest` selects the newest non-sample library sermon with a transcript. Comparison runs Apple then Qwen on the same immutable transcript and writes protected, excluded-from-backup `Documents/NotesTrace/compare-<sermonID>-<timestamp>.json`, with results/reasons, duration per engine, transcript identity/revision, model repo/revision, sampled peak process physical footprint, and engine metrics. It never updates saved notes or the selected engine. Qwen needs to finish downloading before a useful two-engine comparison; a not-ready run records an explicit reason.

Qwen metrics use actual MLX `GenerateCompletionInfo` prompt/output token counters and MLX allocator peak memory, summed across completed passes/retries. Apple metrics use the real SDK's `SystemLanguageModel.tokenCount(for:)` on prompt/response transcript entries, instructions, and schema after successful responses. `tokenCountMethod` explicitly identifies those as re-tokenized transcript counts rather than internal inference counters. Unavailable metrics carry a reason instead of fabricated values. Process footprint is sampled at 100 ms intervals and at run boundaries, so it is a sampled peak rather than a guaranteed instantaneous maximum. Comparison checkpoints live in `NotesTrace/ComparisonJobs`; repeated comparisons can reuse sections, and timings therefore include their current cache state.

### Validation limits

The final core Simulator suite and local-package tests pass; exact commands/results are in `docs/REVIEW.md`. An arm64 iOS Swift diagnostic build passes with `.metal` compilation excluded. **The complete iOS package build is blocked:** this Xcode installation lacks the Metal Toolchain required for MLX's `default.metallib`. The diagnostic artifact is unsuitable for inference and is not a passing complete device build. A full build also requires command-local plugin trust and coverage disabled to work around this Xcode/Swift compiler's isolated-destructor coverage crash. No full model download, real Qwen inference, physical iPhone comparison, signed entitlement/provisioning check, or locked/background inference is claimed. No app, project.yml, web, site, or server files were edited; no commits were made.

## Sermon Notes repair and degradation — CORE-REQUESTS §13 (2026-10-08)

Apple's prompt/checkpoint version is now `sermon-notes-v2`. Map validation repairs useful output instead of discarding a section for an optional field: strip machinery and quotation marks, trim heading/summary/illustration/application word counts, remove unheard names/references, drop junk scripture, and snap a non-verbatim phrase to an exact original span of its cited sentence (at most 20 words), or omit it. God, Jesus, Christ, Lord, Holy Spirit, and Father are allowed; other names can be grounded anywhere in the finalized transcript. Only a summary with no words or remaining machinery fails map validation. Reduction retains its stricter prose/structure checks and degrades on failure.

`ModelSectionNotes` no longer contains `sentenceNumbers`; its single `keyPhraseSentence` remains. Starts come from the first cleaned sentence and evidence from complete supporting section ranges. Apple reserves 400 map response tokens (previously 650), 1,100 reduce response tokens, and a 256-token safety margin. Section sizing counts the actual prompt, including detected references, against instructions + generation schema + reserved response + margin, targeting up to 2,200 input tokens. DEBUG traces add `repairs` (first sentence, field, rule) and `attempts` (stage, attempt, exact `GenerationError` case, and input/limit/instruction/schema/response/safety/context token counts). Fake clients report only the counts they can measure.

Context overflow recursively splits sections until roughly 600 input tokens, or one sentence. Guardrail/refusal errors instead retry each half once with an explicit transformation-of-recorded-Bible-study framing. Persistent errors or empty model summaries recover an extractive note: a content-bearing source sentence supplies the heading and exact phrase, with an empty summary. Good map checkpoints remain reusable; extractive/skipped stretches are retried on regeneration. Cancellation still propagates with completed checkpoints retained.

Every recovered section enters reduction, including exact phrases from extractive sections. If the reduce prompt cannot fit after compaction, generation throws, or both validated reductions fail, deterministic assembly keeps teaching sections in audio order, groups split announced stretches, and uses the best available section summary's first sentence for the big idea. If all summaries are empty, an exact phrase supplies the big idea. The engine label ends in ` (partial)` for deterministic results or results using extractive sections. Deterministic fallback leaves actions/questions empty rather than inventing them. A model unavailable at the initial capability check still returns a reason without fabricating notes; zero usable sections also returns unavailable.

`NotesRole.discussion` has raw value `discussion or question`. Prompts distinguish audience questions/back-and-forth from teaching points; discussions support adjacent points instead of becoming independent points. Deterministic assembly attaches their evidence/scripture to the nearest point. Phrase-only partial points remain editable through `editNotes`, preserving their IDs, exact phrases, and evidence; a point still needs a heading and either a summary or a key phrase.

`ScriptureDetector` is shared by Apple and Qwen. It recognizes canonical books, spoken/ordinal/numeric prefixes, common ASR spellings, numeric and spoken chapter/verse numbers, chapter/verse labels, comma-separated verses, colon references, and verse ranges. It normalizes these into references, supplies `References heard: …` in Apple map/reduce and Qwen whole/map/reduce prompts, and fills missing/invalid `mainPassage` from the most-cited chapter (first heard on a tie). A bare book survives only when that book was heard; numbered references must match a heard chapter/verse reference, allowing a chapter-only form of a heard verse citation. Qwen's checkpoint version is now `qwen35-sermon-notes-v2`, and its map JSON also omits `sentenceNumbers`.

The private device trace was read only by an ignored local replay harness; no transcript or raw model text was added to source, tests, or documentation. Aggregate results: all 8 recorded map attempts now survive validation (previously 0); pipeline replay retains 4 model section notes and recovers 6 extractive notes, covering all 277 cleaned sentences, and reaches reduction. A deliberately failing fake reducer produces partial notes. This verifies repair/pipeline behavior, not new Apple/Qwen inference quality on an iPhone. Synthetic regression fixtures cover each requested failure class. Exact commands, test results, and the complete unsigned device build are recorded in `docs/REVIEW.md`.


## Section 14 — Parakeet Ultra speech package (2026-10-10)

Implemented `Packages/SermonSetSpeech` (product `SermonSetSpeech`) with FluidAudio pinned to **0.17.7**, **`traits: []`**, and a local Core dependency. Core's manifest remains dependency-free. The supplied FluidAudio source at `build/asr-lab/FluidAudio`, revision `fc8c3e4f5103bf63a242453566525272e143a054`, was the API reference and offline validation dependency. Remote release resolution was not attempted under the no-network agreement; the exact release pin is restored in the delivered manifest.

`ParakeetTranscriptionAdapter` converts original/imported audio using FluidAudio's 16 kHz mono Float32 converter, loads Ultra with `AsrModels.loadLocal(from:version: .ultra)`, runs `AsrManager`'s batch path with seam repair and one chunk worker, passes the selected locale as `Language`, then uses `OfflineDiarizerManager` with explicitly constructed local `OfflineDiarizerModels`. It never calls FluidAudio's implicit model downloader. The 25-language allowlist excludes unsupported `Language` enum cases, and reports readable fallback reasons. Memory is checked with `os_proc_available_memory()` on iOS before loading (1 GiB baseline plus recording buffers); Mac evaluation uses reclaimable host memory. Serious/critical thermal states and concurrent heavy speech runs fall back to Apple. ASR is cleaned up before diarization; neither engine's loaded models are retained after a run. On resume, diarization still sees the complete original so its labels do not restart at the ASR checkpoint offset.

Words use FluidAudio's repaired word timings and mean subtoken confidence. Sentences split at punctuation, speaker changes, or 30 seconds; confidence is the mean word confidence. `TranscriptSegment.speaker` and `speechDuration` are optional Codable fields, so older documents decode nil. `Transcript.primarySpeaker` is derived from timed speech duration, excluding sentence-internal silence. Labels are anonymous, not guesses about people's identities. There is no speech enhancement or generic vocabulary boosting.

FluidAudio's public batch API emits chunk progress but exposes word timings only after the batch seam merge. Core's adapter protocol therefore has a compatible `onProgress` overload (existing adapters keep their old method). Genuine ASR and diarization progress drives the store per chunk; finalized sentences are checkpointed through `onSegments` after inference. No interim words or empty placeholder segments are fabricated. Store progress is monotonic, including when final sentence checkpoints arrive after inference progress.

`SpeechModelManager` reuses the local notes manager's background-transfer design in a speech-only implementation, without linking MLX. Its observable `state` uses `notDownloaded/downloading/paused/ready/failed`; public controls are `start`, `pause`, `cancel`, `delete`, and persisted `allowCellular`. It starts only after network policy is known, treats expensive paths as cellular, uses request-level cellular/expensive-network restrictions, persists resume data and transfer journals, recovers background Inbox deliveries, checks disk space, and verifies every downloaded file's size and SHA-256 before installation. Its background session identifier is `com.gazhenko.sower.speech.model-download`; forward app background-session completion to `handleBackgroundEvents(identifier:completion:)`. The model directory is Application Support/SermonSet/LocalModels/Speech-ultra-diarization-v1, excluded from backup and protected on iOS. The manifest covers 39 files / **653,762,381 bytes**, derived from the supplied real cache. Diarization downloads pin HF revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`; Ultra uses its upstream main URLs with reviewed file hashes, so changed bytes fail verification. Cached models were read through symlinks in ignored build fixtures; the shared cache was not changed.

Core persists `SermonStore.transcriptionEngine` (`.parakeet` by default, `.apple` optional), chooses the injected Parakeet factory only when available, otherwise selects the per-sermon Apple adapter, and stamps the actual adapter's `engineName`. `transcriptionFallbackReason` is available for a readable explanation. Both `transcribe` and `processRecording` use this selection. `retranscribe(sermonID:) async` starts at original time zero, retains earlier revisions, separates checkpoints by engine, rebases identical evidence onto the new revision, preserves changed citations against the retained old revision and marks affected takeaways/outline for review, keeps moments/personal-note timestamps, and regenerates insights/notes while preserving listener edits. Apple now retains overlapping final results, dropping only exact text/time duplicates. Its `AnalysisContext.contextualStrings[.general]` receives known preacher, church, and passage-book names.

DEBUG hooks are exposed through `SpeechModelManager.runLaunchArguments(store:arguments:)`: `-SermonSetDownloadSpeechModel` starts the managed download; `-SermonSetCompareTranscripts <UUID|latest>` runs both engines against the same original file and writes protected, backup-excluded `Documents/TranscriptTrace/compare-<id>-<timestamp>.json`. The trace includes both transcripts, anonymous speakers, segment timings/confidences, primary speaker, word counts, audio and processing durations, per-run sampled peak resident process memory (20 ms samples, including app baseline), and explicit errors for unavailable runs. Comparisons do not change saved transcripts, revisions, insights, or jobs. These are local DEBUG artifacts, not analytics or uploads.

### Exact project.yml additions for Claude

Under the existing top-level `packages:` mapping:

```yaml
  SermonSetSpeech:
    path: Packages/SermonSetSpeech
```

Under `targets.SermonSet.dependencies`, alongside the Core and LocalModel entries:

```yaml
      - package: SermonSetSpeech
        product: SermonSetSpeech
```

App-side integration is still Claude's slice: `import SermonSetSpeech`; retain one `SpeechModelManager` in app state; call `speechModels.install(in: store)` immediately after store creation, before starting recording processing; refresh capabilities after installation/model state changes; call `try await speechModels.runLaunchArguments(store: store)` from the launch task and surface any error. Bind Settings to `store.transcriptionEngine`, `speechModels.state`, and the manager controls. Use `segment.speaker` / `transcript.primarySpeaker` in the transcript UI, and `await store.retranscribe(sermonID:)` for retry. Forward the speech background-session identifier as described above. No `SermonSet/`, project.yml, web, site, or server edits were made by this task, and no commits were made.

Verification includes simulator Core tests, speech unit tests, actual cached Ultra/offline-diarizer inference on the public 4.6-minute AMI fixture (79 sentences, five speakers, 160 progress callbacks), the requested unsigned app device build, and an isolated unsigned framework device build that actually links SermonSetSpeech. Exact commands/results are in REVIEW. This is Mac inference plus simulator/build evidence, not physical-iPhone transcription, thermal/background validation, or a live model-download test.


## Section 15 — queued Parakeet, model decoding recovery, and speaker-aware notes (2026-10-10)

Parakeet now uses one shared FIFO runtime gate instead of reporting busy as unavailable. Waiting jobs allocate no models, retain their original recording/checkpoint, and resume with Parakeet when the active run releases its models. Cancellation removes a queued job; success, failure, and active cancellation release the next job. Capability checks defer memory/thermal decisions while the shared runtime is occupied; the real Fluid runtime rechecks recording-sized memory headroom and thermal state after waiting. Missing models and unsupported languages still select Apple immediately, and genuine load/memory/thermal failures still use the existing Apple fallback. Cancellation during model loading stays cancellation.

Core adds a compatible `TranscriptionAdapter.transcribe(fileURL:startingAt:onProgress:onWaiting:onSegments:)` overload, with a default forwarding implementation for existing adapters. Parakeet reports `onWaiting(true)` while queued and `false` when starting. The store sets transcription to `.running(progress: nil)` and `notesStageDetail` to exactly **“Waiting for the other recording”**, then clears that detail on start or cancellation. The existing app integration requires no new app or project configuration.

Foundation Models `GenerationError.decodingFailure` and Swift `DecodingError` now recover at each response boundary: insights chunks, notes sections, notes reduction, legacy summary reduction groups, and the legacy final summary. A failed response gets one retry. Persistent chunk/group failures leave that unit uncached and continue with the remaining sermon; failed notes sections retain the existing exact-source extractive recovery, and failed notes reduction assembles partial section notes. A failed final legacy summary records its unavailable reason while retaining takeaways. Cancellation propagates. The store also isolates takeaway and notes inference failures, so either artifact can still be saved when the other engine throws; listener edits and accepted results keep their existing preservation rules.

Both Apple and Qwen (whole-transcript and section paths) use speaker-aware sentence lines: `[n] Preacher: …`, `[n] Speaker 2: …`, etc., only when more than one named speaker exists. Unknown speech is labelled `Unidentified speaker` in that case. Cleaning flushes at every speaker boundary. Non-primary/unknown speech becomes discussion and cannot announce the preacher's points. Instructions require points from the preacher and classify other speakers as questions/discussion. Shared key-phrase validation, normalization repair, whole-transcript selection, and extractive selection require every source segment to belong to `Transcript.primarySpeaker` whenever labels exist. Unlabelled transcripts keep their prior prompt/phrase behavior. Prompt versions are now Apple notes `sermon-notes-v3`, Qwen `qwen35-sermon-notes-v3`, and insights/legacy summary `sermon-notes-v2`, invalidating earlier incompatible checkpoints.

Regression coverage exercises FIFO overlap, cancellation and failure release, busy versus genuine low-memory readiness, waiting UI state, both decoding error forms at every Foundation Models generation stage (transient and persistent), independent saving, and speaker attribution in both Qwen prompt paths and the Apple engine. Required simulator tests, both optional package suites, and the unsigned device app build passed using cached dependencies and the existing offline FluidAudio checkout. Exact commands, skipped opt-in tests, early failures, and validation limits are in `docs/REVIEW.md`. No physical-iPhone or live model inference validation was performed in this slice. No changes to `SermonSet/`, root `project.yml`, `web/`, `site/`, or `server/`; no commits.

## Section 16 — Parakeet load diagnostics, compute recovery, and foreground downloads (2026-10-10)

Parakeet preserves its listener-facing load/fallback message and now carries the real model error through `TranscriptionUnavailableError.debugDetail`. `SermonStore.transcriptionFallbackDebugDetail` retains it after Apple fallback succeeds; DEBUG builds also append it to `transcriptionFallbackReason`. Release listener copy remains unchanged. `SpeechComparison.Run.debugDetail` records exhausted recovery; successful Parakeet comparisons include `modelDiagnostics`, covering each component's filename, requested compute units, load/first-prediction stage, NSError domain/code/description, and nested underlying errors. `Logger` uses subsystem `com.gazhenko.sower`, category `SpeechModels`. Diagnostics are local; no new transcript uploads or analytics.

The supplied FluidAudio API exposes `AsrModels.loadLocal(from:version:configuration:encoderPrecision:encoderComputeUnits:)`. Its implementation pins the split preprocessor to CPU and permits explicit encoder placement. Sower uses its public `AsrModels` initializer plus explicit local `MLModel` loads to apply independent placement to the encoder, decoder, and joint as well. Each component attempts **cpuAndNeuralEngine → cpuAndGPU → cpuOnly**, loading and making a disposable tensor prediction using its declared input shapes before handing it to FluidAudio. Those probe outputs never become transcript words. A successful prediction persists that component's choice in protected, backup-excluded `compute-units-ultra-diarization-v1.json`; subsequent runs start there. Revision changes use another cache. Unvalidated group-retry choices are not persisted. Preprocessor and FBank retain FluidAudio's CPU-only placement. Cancellation propagates without trying the next compute unit.

ASR and diarization recover independently. If a FluidAudio batch prediction throws after the component probes, its API does not expose the failing component: the trace explicitly identifies the ASR or diarization group, records all requested placements and the real error, and retries that group with the next placements. ASR models are released before diarization. Segmentation, Embedding, and PldaRho use independent component retries; PLDA parameter read failures name `plda-parameters.json`. Exhausted diarization returns the successful Parakeet words with nil speaker labels, retaining Parakeet provenance. It never selects Apple solely because speaker processing failed.

Both `SpeechModelManager` and `LocalModelManager` now start up to **four foreground downloads**. Their public controls/state and existing app integration remain compatible. Core's shared `ModelDownloadTransport` observes iOS activity automatically: outstanding foreground tasks migrate using resume data to the existing background-session identifiers on background entry, then return to the foreground session when the app returns. A short iOS background task covers the handoff. No additional manifest files are enqueued while backgrounded; foreground return fills available slots. This needs no app-source or project configuration changes. Transfer generations reject late progress/files/errors from replaced tasks; tokens remain stable across migration. An orphan restoration discards only its own task.

Progress fractions sum verified bytes plus every active file's received bytes over the complete manifest's bytes; speed uses the aggregate byte delta. The journal stores all active transfers and incoming filenames, while still decoding the old single-transfer journal. Restoration recovers multiple retained Inbox deliveries; parallel verification cannot mark ready until every file is installed. Pause saves each file's resume data and request policy; cancel/delete reject late completions and retain verified files as before. Resume data with an outdated cellular policy is discarded for that file. Both managers wait for network policy and treat expensive paths as cellular. Disk reservations include the remaining manifest, up to four simultaneous temporary files, and 512 MiB. File hashes, original audio, backup exclusion, and protection remain in force.

Regression coverage includes ANE load failure succeeding on GPU, first-prediction failure through CPU, exhausted placements, independent component/revision preferences, cancellation, speaker-only failure preserving words, debug detail surviving Apple fallback and trace serialization, four simultaneous foreground transfers, byte-weighted progress, out-of-order completion, pause/resume, foreground-only refill, multi-file relaunch recovery, and actual URLSession task migration with suspended no-network test sessions.

The required simulator Core suite (118 reported tests), Speech suite (25 reported tests), LocalModel suite (18 tests), and unsigned device app build pass. The standard Core/Speech suites each skip one opt-in test; the supplied public ASR cache/audio was also exercised separately with the real FluidAudio runtime. Exact commands and outcomes are in REVIEW. Physical iPhone 17 Pro/A19 Pro execution-plan recovery and live download speed/background scheduling remain unvalidated; the no-network agreement also prevents a fresh remote FluidAudio release resolution. No `SermonSet/`, `project.yml`, `web/`, `site/`, `server/`, or script edits; no commits.

## Section 17 — Voice Focus preview API (2026-10-10)

The exact UI-facing API is available from `SermonSetCore`:

```swift
public struct VoiceFocusPreview: Sendable, Equatable {
    public var original: URL
    public var focused: URL
    public var start: TimeInterval
    public var duration: TimeInterval
}

// @MainActor, on SermonStore
public func previewVoiceFocus(
    sermonID: UUID,
    strength: Double,
    processMusic: Bool,
    around time: TimeInterval?
) async throws -> VoiceFocusPreview
```

Pass the listener's playhead as `around`, or `nil` for automatic selection. The excerpt is 20 seconds, clamped to the saved original/imported/sample trim and decoded playable duration. Playhead requests clamp to the last complete excerpt when near the end; trims shorter than 20 seconds return their complete duration. Automatic selection starts at trim start + 30 seconds, rejects the full renderer's sustained music detections and near-silent windows, and requires audible audio in at least 75% of its 0.4-second blocks. For trims shorter than 50 seconds, it searches from trim start. When no eligible speech window exists, it throws a readable `SermonSetError` suggesting a playhead preview. Automatic selection skips music even when `processMusic` is true; a playhead request can explicitly preview music.

Both paths use `VoiceFocusRenderer`, the same mono downmix, high-pass/presence filters, gate/compressor, sustained music bypass, strength, and four-times peak limiter. The preview aligns blocks with the full trim and warms filter/envelope state before the excerpt. The full render and preview now share a bounded whole-trim loudness estimate: up to twelve evenly distributed 1.2-second windows, K-weighted with the existing absolute/relative gating. The source sample cache is keyed by checksum + effective trim, with file size/mtime invalidation; it retains at most four source/trim analyses in memory. Settings-specific gains reuse those samples and are cached separately. Concurrent requests share an in-flight source estimate. Both paths apply that same estimated gain toward -16 LUFS, bounded to -30…+18 dB; the full copy's gain is no longer determined by an excerpt or a separate normalization decision. As an estimate, it does not promise exact -16 LUFS for every recording.

`original` and `focused` are protected, backup-excluded, lossless mono PCM `.caf` files in `Caches/VoiceFocusPreview/<request UUID>/`. They have equal decoded lengths; the original excerpt receives only a linear gain matching the focused excerpt's integrated loudness. No `AudioAsset`, provenance, job, library document, or `lastError` is changed. Live stores use the app's Caches directory; test/preview stores isolate Caches under their own root. The original recording is only read.

A newer call cancels the preceding request and deletes its pair. Cancel the caller's Swift `Task` to cancel a request when the listener leaves the preview. Superseded/cancelled requests throw `CancellationError` and cannot return stale files or delete the newer request's files. Store initialization removes leftover preview files, including those left by a terminated app. Treat the URLs as valid only until the next preview request or app launch.

Accelerate performs the existing filter, spectral, loudness, and peak calculations in buffers; regression tests compare the filter/compressor, meter, and limiter with their scalar formulas. Tests also cover selection, music/quiet skipping, trim/playhead bounds, matched A/B loudness, agreement with a full-copy excerpt, gain cache/invalidation, cancellation races, temporary cleanup, original checksums, and unchanged library files/assets.

The Debug macOS timing fixture (bundled 48 kHz AAC speech, 20-second playhead excerpts) measured **0.697 s cold**, **0.676 s with cached source/new settings**, and **0.483 s with cached gain**. Exact simulator results and commands are recorded in `docs/REVIEW.md`. These measurements are local fixture evidence; physical iPhone latency/listening has not been validated. Only `Packages/SermonSetCore` and these two documentation files are edited by this task; existing/concurrent UI work is preserved. No commits.

## Section 18 — Automatic Voice Focus and listening preference (2026-10-10)

Exact new public API names for Claude, exported by `SermonSetCore`:

```swift
// All SermonStore members are @MainActor.
public var voiceFocusAfterRecording: Bool { get set } // persisted; default true
public func processVoiceFocusAfterRecording(sermonID: UUID) async
public func preferredListeningAssetID(for sermonID: UUID) -> UUID?
public func preferredListeningAsset(for sermonID: UUID) -> AudioAsset?
public func setPreferredListeningAsset(_ assetID: UUID?, for sermonID: UUID) throws

// On ProcessingJobs (Codable):
public var voiceFocus: JobState
// Its existing initializer gains its final defaulted argument:
public init(transcription: JobState = .idle, insights: JobState = .idle,
            summary: JobState = .idle, voiceFocus: JobState = .idle)
// On AudioDerivativeProvenance (Codable):
public var madeAutomatically: Bool?
```

`processRecording(sermonID:)` retains its explicit transcription/notes behavior and now starts `processVoiceFocusAfterRecording(sermonID:)` alongside those stages when the new preference is on. Notes can finish and appear while Voice Focus is still `.running(progress: nil)`; the method returns after both branches settle. The renderer's duration probe, checksums, loudness analysis and DSP run off the main actor. A render failure leaves its listener-readable `.failed(message:)` on `store.jobs(for: sermonID).voiceFocus`, does not fail the notes pipeline, and does not replace `lastError` with an automatic-copy error. Store-owned tasks deduplicate overlapping calls and survive cancellation of the view's awaiter. The existing continued-processing lease cancels both branches on expiration. Interrupted Voice Focus work is journaled separately and resumes from the original on launch/foreground; completed copies are reused without changing a later listener choice. Terminal rendering failures require an explicit retry and do not loop on each launch.

**Recorder integration for Claude:** the current recorder only calls `processRecording` inside its `summarizeAfterRecording` gate. Keep that explicit notes call, and add the Voice Focus-only call when automatic notes are off:

```swift
if store.summarizeAfterRecording {
    Task { await store.processRecording(sermonID: sermon.id) }
} else if store.voiceFocusAfterRecording {
    Task { await store.processVoiceFocusAfterRecording(sermonID: sermon.id) }
}
```

This package task does not edit the recorder or settings UI. Claude can bind a toggle directly to `voiceFocusAfterRecording` and show the independent `jobs(for:).voiceFocus` state. The standalone Voice Focus-only call has durable foreground/relaunch recovery but does not submit the summary's continued-processing lease. There are no new Info.plist keys or background modes in this slice.

The automatic copy uses the original/imported source, strength **0.5**, `processMusic: false`, and the **full decoded recording** starting at zero, ignoring any saved sharing trim. Provenance has `madeAutomatically == true`; new manual copies have `false`, and older documents decode it as `nil` (treat as manual). Originals remain canonical and unchanged. Transcription, retranscription, Parakeet routing and Apple fallback still read the original/imported asset and store evidence on that timeline. Sharing retains its existing explicit derivative/trim selection and validation; the listening preference never selects sharing audio.

`preferredListeningAssetID(for:)` returns the stored choice, which may refer to a now-missing asset. `preferredListeningAsset(for:)` resolves an available local choice, falling back to the canonical source if the choice or its file is absent; official choices still require current authorization. `setPreferredListeningAsset(_:for:)` accepts an available local asset belonging to that sermon, or `nil` to reset to canonical playback. `PlaybackController.load(sermonID:autoplay:)` resolves this preference, including a changed preference or missing copy on a repeated load. `selectAudioAsset(_:levelMatched:acknowledgeMomentShift:)` and `revertToOriginal()` persist explicit player choices. Listening positions remain original timestamps, including trimmed manual copies after reopening. Full automatic copies report `.original` alignment; trimmed copies report their source offset.

`play(moment:)` keeps a preferred Voice Focus copy when it covers that moment and cites the moment's original source. A moment outside a trimmed copy uses the original temporarily, opening its full timeline if a saved sharing trim would hide that moment, without changing the preferred listening asset. Moment/note records keep their original anchors and times. A successful manual `renderVoiceFocus(sermonID:strength:processMusic:)` becomes preferred, removes superseded automatic metadata/files, and retains original and existing manual files. A manual render takes precedence over any in-flight automatic render; cancelled or older requests cannot save a stale copy or change preference. Explicit anchors on a deleted automatic copy move to its original at the same timestamps.

Regression coverage includes preference defaults/persistence and legacy decoding, full-length recommended rendering despite a saved trim, provenance/checksums/anchors, slow-render notes completion, view cancellation/deduplication, independent failure/disable behavior, source switching and missing/removed-file fallback, moment alignment, manual file replacement and render races, original-only manual/automatic/retranscription paths including both ASR engines/fallback, interrupted-copy relaunch recovery, and deletion during rendering. Exact verification commands and outcomes are in `docs/REVIEW.md`; physical iPhone listening and background execution have not been exercised.
