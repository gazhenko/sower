# SermonSetCore prototype review — October 5, 2026

Backend implementation is complete for the assigned prototype boundary. The current core gate passes **37 Swift Testing tests**, the full app builds, and the earlier **2 selected Claude-authored UI journeys passed**. This is Simulator evidence, not physical-iPhone validation. The macOS-host speech attempt below is blocked by missing installed English assets. No commits, pushes, branches, releases, dependency installations, credentials, or application network calls were used.

## Environment and executed commands

Working directory: `/Users/jemmygazhenko/Documents/GitHub/sermonset-ios`.

- `xcodebuild -version`: Xcode 26.6, build 17F113.
- `xcrun --sdk iphonesimulator --show-sdk-version`: 26.5. The installed SDK is not labeled 26.6.
- Destination for every Simulator execution: `platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C`, SermonSet Core (Codex), iPhone 17 Pro, iOS 26.5.
- DerivedData: `build/DerivedData-core` only. Other booted simulators were neither operated on nor shut down.

| Exact command | Outcome |
| --- | --- |
| `scripts/dev.sh generate` | Passed; generated SermonSet.xcodeproj with local package, app, independent core checks, package test action, and UI-test target. |
| `scripts/dev.sh test > build/codex/test-first.log 2>&1` | Original run: 23/25 passed. Failed model-availability assumption and Simulator Data Protection expectation. |
| `scripts/dev.sh test > build/codex/test-resume-baseline.log 2>&1` | Resume baseline: reproduced 23/25, exit 65. Original two failures confirmed against the current tree. |
| `scripts/dev.sh test > build/codex/test-platform-fixes.log 2>&1` | 25/26 passed, exit 65. Both original failures fixed; new moment test exposed ISO-8601 whole-second creation-date precision. |
| `scripts/dev.sh test > build/codex/test-complete.log 2>&1` | **30/30 passed**, 3 suites, exit 0, `TEST SUCCEEDED`. Swift Testing execution took 5.758 seconds. Result: `build/logs-core/tests-20261005-011444-85252.xcresult`. |
| `scripts/dev.sh build > build/codex/app-build.log 2>&1` | **Passed**, exit 0, `BUILD SUCCEEDED`. Full current SwiftUI app and core compiled together. |
| `python3 scripts/build-samples.py > build/codex/samples.log 2>&1` | Passed with allowed fallback: requested Kokoro voice assets were absent from the offline cache; installed Samantha generated all 8 samples. No model/package downloads. |
| `python3 scripts/build-samples.py --say > build/codex/samples-final.log 2>&1` | Passed; final sample resources use Samantha at the script's current narration rate. 6,342,936 audio bytes plus JSON, 48 kHz mono AAC at a requested 64 kbps. Current source hash matches generated metadata. |
| `scripts/dev.sh run -SermonSetPreviewData -SermonSetSimulatedCapture > build/codex/preview-run.log 2>&1` | Passed: build, install, and launch on the assigned simulator; launch returned PID 87595. |
| `scripts/dev.sh screenshot build/codex/preview.png > build/codex/preview-screenshot.log 2>&1` | Passed; PNG written under ignored build output. This is startup evidence, not a visual/accessibility sign-off. |

The script expands core checks to the following command (its actual result-bundle path is recorded above and in the log):

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261005-011444-85252.xcresult test
```

Earlier incremental native core builds used this exact command, redirecting respectively to `build/codex/domain-build.log`, `build/codex/capture-build.log`, and `build/codex/adapters-build.log`; all three finished `BUILD SUCCEEDED`. The capture build initially reported converter-closure Sendable warnings; the subsequent adapter and final core builds have no Swift concurrency diagnostics.

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

## App journeys and project integration

Executed this exact selection against Claude's UI tests without editing their Swift files:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSet -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -resultBundlePath build/logs-core/ui-journeys-core.xcresult \
  -only-testing:SermonSetUITests/SermonSetJourneyTests/testRecordMarkNoteStopAndRevisit \
  -only-testing:SermonSetUITests/SermonSetJourneyTests/testEveryLookRendersTheLibrary \
  test > build/codex/ui-journeys.log 2>&1
```

Passed 2/2, exit 0, `TEST SUCCEEDED`:

- `testRecordMarkNoteStopAndRevisit`: 38.311 seconds. Launched with `-SermonSetUITest`, `-SermonSetSimulatedCapture`, and a unique directory; exercised consent UI, recording, two marked moments, note entry, stop/save, revisit, and library persistence across app relaunch. No microphone prompt blocked the journey.
- `testEveryLookRendersTheLibrary`: 26.632 seconds. Preview library rendered under riso, rubric, vespers, and lumen. Screenshots are retained as test attachments in `ui-journeys-core.xcresult`.

The pack/trade **UI** journey was not selected. Its core invariants are covered by Swift Testing. No physical microphone or live AI success is inferred from either UI journey.

`SermonSetUITests` is configured in project.yml and the app Test action alongside the Swift package tests. The independent `SermonSetCore` scheme remains available while UI files change. All three requested alternate-icon asset names are enabled. This inspection passed and showed their entries in the compiled app plist:

```sh
plutil -extract CFBundleIcons json -o - build/DerivedData-core/Build/Products/Debug-iphonesimulator/SermonSet.app/Info.plist
```

## Verified core behavior and platform corrections

Tests exercise atomic store round-trip, preservation/write blocking for corrupt or unknown-schema stores, write-failure rollback, idempotent sample/pack/card keeps, ISO-week pack selection and reload stability, and trade preview retaining history/audio/transcripts/notes/moments. Import copies audio with duration and checksum; deletion removes the copied asset. Export includes private notes and metadata while omitting audio bytes and local audio paths. Backup exclusion flags toggle and persist.

Capture tests use real synthesized AAC files. They check manifest existence, segment finalization, pauses excluding elapsed time, saved annotations referencing the original asset, immutable audio after metadata edits, checksum-verified recovery from a copied session snapshot, rejection of corrupt segments without deleting them, unlisted partial-container handling, dismiss-without-delete, idempotent recovery, injected interruptions/routes/media reset, and capture/playback handoff. The launch-argument combination also has a direct core record → mark → stop test with simulated permission granted.

`updateMoment(_:)` edits only note text, retains original identity/time/audio source/creation time, rejects a mismatched sermon, clears notes with nil, and persists the edited note. Its reload assertions account for version-1 whole-second ISO-8601 date precision while preserving numeric audio timestamps exactly.

Processing tests validate finalized evidence ranges/revisions, low-confidence flags, extractive verbatim output and moment weighting, invalid-citation rejection, invented straight/curly quotations, contraction preservation, bounded Unicode chunks, confidence-sensitive transcript hashing, fallback if a model becomes unavailable during generation, and speech checkpoint retry after relaunch. The original verification compiled the actual Apple adapters and queried availability without invoking inference or asset installation. The follow-up host attempt and Claude's reported model inference are distinguished below.

- `backupFlagAndFileProtectionPersist` continues to check backup flags on Simulator. Its Data Protection expectation runs only on physical iOS (`os(iOS) && !targetEnvironment(simulator)`). Production code still requests `.completeUntilFirstUserAuthentication` on directories, atomic JSON writes, and audio files. **Data Protection is not verifiable on Simulator.** A passing Simulator test does not prove that protection is applied.
- `realCapabilityReportsRemainOnDeviceWithoutInstallingAssets` asserts on-device reporting, zero asset-preparation calls through a probe wrapping the real speech availability check, idle processing jobs, and no processing checkpoint directory. It makes no assumption about model availability on the host and never calls AssetInventory installation. The baseline host reported the Foundation Models model available, which was a valid runtime result rather than a backend failure.

Build/test output includes Apple's benign AppIntents metadata-extraction notices and Simulator audio LoudnessManager/HAL messages. These are preserved in logs; no physical acoustic fidelity is claimed.

## Capture-start cleanup and service-date follow-up

Rechecked the current tree with `git status --short`; the prototype directories remain untracked. Both independently reported bugs were reproduced through the real public methods before applying their fixes. The initial regression run also caught a test-only full-history equality assertion affected by the documented whole-second ISO-8601 date precision; that assertion now checks unchanged history in memory and compares persisted acquisition time within its supported precision.

`CaptureController.start(_:)` failure now cancels its ticker, stops/drains and clears the engine, and ends its own audio-session ownership. If no audio was captured and no segment exists after stopping, it removes the empty session directory and clears the journal; `.failed(error)` remains visible, and the same controller can immediately start again. Captured audio remains protected: finalized segments, including buffered audio finalized during failure cleanup, retain the journal for `stop()` or `discard()`. Captured nonzero duration also preserves the journal if flushing failed. Engine failure callbacks carry their session ID so a delayed callback from the failed engine cannot interrupt a new recording. The public capture initializer is unchanged; engine-factory injection is internal.

Three new capture tests exercise real `SimulatedCaptureEngine` instances and the production AAC writer:

- An empty engine-start failure stops the injected engine once, deletes its session directory, leaves no recovery/library entry, and supports a new record → mark → stop flow on the same controller. A delayed callback from the previous engine leaves the retry recording active.
- Failure while claiming audio-session ownership occurs after the manifest exists and before engine creation. It removes that empty session, retains the other owner's claim, and permits retry after that owner ends capture. This is an injected ownership conflict, not a physical phone-call test.
- Finalized and buffered-before-failure AAC are checked in both save and discard paths. Cleanup flushes the buffered case, preserves checksum-valid audio, rejects a premature new start, supports saving an immutable original or explicit discard, and permits a later start. Saving/discarding does not stop the already-cleared failed engine again.

`SermonStore.updateSermon(_:)` now accepts `serviceDate`. Its new test checks the observable sermon/library entry and a reopened store, rejects caller changes to stored `createdAt`, and retains acquisition history and the canonical audio reference. No public signatures or schema fields changed.

All commands below used the assigned Codex simulator and `build/DerivedData-core`; the script regenerated the Xcode project. No UI, UI-test, or asset-catalog source files were edited. Exact outcomes:

| Exact command | Outcome |
| --- | --- |
| `scripts/dev.sh test > build/codex/test-start-date-before.log 2>&1` | 33/37 passed; the 4 new tests failed with 17 issues, exit 65, `TEST FAILED`. Includes the test-only date-precision assertion described above. Result: `build/logs-core/tests-20261005-015631-93945.xcresult`. |
| `scripts/dev.sh test > build/codex/test-start-date-complete.log 2>&1` | 37/37 passed, 3 suites, 5.895 seconds, exit 0, `TEST SUCCEEDED`, after cleanup/date fixes and the precision-aware assertion. Result: `build/logs-core/tests-20261005-015923-94350.xcresult`. |
| `scripts/dev.sh test > build/codex/test-start-date-stale-callback-before.log 2>&1` | 36/37 passed, 1 issue, exit 65, `TEST FAILED`. Newly injected delayed callback changed the retry's phase to interrupted. Result: `build/logs-core/tests-20261005-020055-94600.xcresult`. |
| `scripts/dev.sh test > build/codex/test-start-date-final.log 2>&1` | **Final: 37/37 passed**, 3 suites, 5.923 seconds, exit 0, `TEST SUCCEEDED`, including the session-bound callback guard. Result: `build/logs-core/tests-20261005-020206-94802.xcresult`. |
| `scripts/dev.sh build > build/codex/app-build-start-date-final.log 2>&1` | **Final: passed**, exit 0, `BUILD SUCCEEDED`. Full app and core compiled together after both fixes and the callback guard. |

The final build/test logs contain no Swift warnings or errors; the benign AppIntents metadata-extraction warning remains. No live microphone, physical call, iPhone Data Protection, or live speech/model inference was exercised in this follow-up. UI journeys were not rerun; the previous UI journey and macOS-host evidence below retain their original scope.

## Quote-handling follow-up and macOS-host speech evidence

Rechecked `git status --short`: the prototype directories and configuration remain untracked in this checkout. The current source already preserved simple `Peter’s` and `don't` cases. Three new regression tests reproduced the remaining quote problems: nested curly single quotes left delimiters behind, a leading U+2019 quote was retained, and the quotation guard missed quoted text spanning a newline. `scripts/dev.sh test > build/codex/test-quotes-before.log 2>&1` ran 33 tests; 31 passed and 2 failed with 3 issues, exit 65. Result: `build/logs-core/tests-20261005-013915-90651.xcresult`.

`EvidenceValidator` now matches nested quotation spans without treating U+2019 or ASCII apostrophes between letters/numbers as delimiters. Paraphrases remove paired and boundary quotation marks while preserving contractions, `Peter’s`, unpaired possessives within a sentence, and internal literal double marks such as `3" nail`. A final isolated probe reproduced the old literal result `Use a 3 nail here.` before removing the blanket double-mark filter; that literal case now has a core regression expectation. The invented-quotation guard checks the original text before stripping, including nested and multiline spans. Tests cover the validator plus actual generated-takeaway validation and the bundled “Breakfast on the Shore” takeaway loader. The model checkpoint's internal prompt/validation version is now `bounded-evidence-v2`, so regeneration does not reuse sanitized v1 chunk outputs. Existing persisted insights and listener edits are not rewritten to guess lost punctuation; preview/sample reload and fresh generation use the corrected validator.

After the quote fix, `scripts/dev.sh test > build/codex/test-quotes-complete.log 2>&1` passed 33/33 in 3 suites, 5.725 seconds, exit 0, `TEST SUCCEEDED`, result `build/logs-core/tests-20261005-014153-91130.xcresult`. `scripts/dev.sh build > build/codex/app-build-quotes.log 2>&1` passed, exit 0, `BUILD SUCCEEDED`. Final commands after the checkpoint-version change are recorded below.

| Exact follow-up command | Outcome |
| --- | --- |
| `scripts/dev.sh test > build/codex/test-quotes-final.log 2>&1` | **33/33 passed**, 3 suites, 5.651 seconds, exit 0, `TEST SUCCEEDED`. Result: `build/logs-core/tests-20261005-014315-91412.xcresult`. |
| `scripts/dev.sh build > build/codex/app-build-quotes-final.log 2>&1` | **Passed**, exit 0, `BUILD SUCCEEDED`. Full app and local package compiled after the quote fix and checkpoint-version change. |
| `scripts/dev.sh test > build/codex/test-quotes-literal-final.log 2>&1` | **Final: 33/33 passed**, 3 suites, 5.770 seconds, exit 0, `TEST SUCCEEDED`. Includes the literal internal double-mark regression. Result: `build/logs-core/tests-20261005-014751-92046.xcresult`. |
| `scripts/dev.sh build > build/codex/app-build-quotes-literal-final.log 2>&1` | **Final: passed**, exit 0, `BUILD SUCCEEDED`. Full app includes the final literal-mark correction and v2 checkpoint invalidation. |

No Swift diagnostics were reported; the app build retained the benign AppIntents metadata-extraction warning. The earlier two UI journeys were not rerun for this backend-only follow-up. No UI or UI-test sources were edited.

Exact isolated literal probe commands, executed before removing the blanket double-mark filter (compilation and process exit 0; printed `literalRetained=false`, reproduced the regression):

```sh
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path build/codex/speech-host/ModuleCache \
  Packages/SermonSetCore/Sources/SermonSetCore/Domain.swift \
  Packages/SermonSetCore/Sources/SermonSetCore/Evidence.swift \
  build/codex/speech-host/QuoteProbe.swift -o build/codex/speech-host/quote-probe \
  > build/codex/speech-host/quote-compile.log 2>&1
build/codex/speech-host/quote-probe > build/codex/speech-host/quote-before.log
```

**macOS-host evidence only, not iPhone evidence:** macOS 26.4 (25E246), Apple silicon (`arm64`), Apple Swift 6.3.3. A throwaway harness in ignored `build/codex/speech-host/` compiles the unmodified production `Domain.swift` and `SpeechAdapter.swift`, avoiding changes to the package or iOS target. The production adapter was invoked against the bundled `open-hands.m4a`, readable at 48 kHz with 5,045,685 frames and a duration of 105.1184375 seconds.

Exact compilation and attempt commands:

```sh
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path build/codex/speech-host/ModuleCache \
  Packages/SermonSetCore/Sources/SermonSetCore/Domain.swift \
  Packages/SermonSetCore/Sources/SermonSetCore/SpeechAdapter.swift \
  build/codex/speech-host/Attempt.swift -o build/codex/speech-host/attempt \
  > build/codex/speech-host/compile.log 2>&1
build/codex/speech-host/attempt \
  Packages/SermonSetCore/Sources/SermonSetCore/Resources/Samples/open-hands.m4a \
  > build/codex/speech-host/attempt.log 2>&1
```

Compilation passed, exit 0. The harness exited 0 after reporting a **blocked transcription**, not successful inference:

- `SpeechTranscriber.isAvailable == true`; supported equivalent locale is `en_US`.
- `AssetInventory.status(forModules:) == .supported`, rather than `.installed`; production `capability()` returned `.needsDownload`.
- Production `transcribe(fileURL:startingAt:onSegments:)` threw `SermonSetError(title: "Speech unavailable", message: "On-device English speech assets are unavailable. The recording has been preserved.")` before creating the analyzer.
- **Zero segments produced; timestamp sanity and confidence presence are not verifiable.** The live SpeechAnalyzer result path could not run on this host without installing English assets. No asset reservation, preparation, installation, microphone access, or speech-authorization prompt was invoked. Legacy speech authorization was `.notDetermined` (raw value 0).

This establishes compilation, file readability, and the runtime asset blocker; it does not establish live transcription correctness. The harness and logs remain under ignored build output for inspection.

**Attributed observation from Claude's Simulator UI run, reported in the follow-up:** `generateInsights` using Apple Foundation Models on-device produced three takeaways with valid evidence timestamps, a low-evidence flag, and an outline from the “Breakfast on the Shore” sample transcript. Codex did not independently repeat that inference run. It demonstrates the reported model path on Simulator with a fixture transcript; it does not validate live speech transcription or physical-iPhone inference quality.

## Remaining evidence limits

**Blocked / not executed on physical iPhone:** Data Protection enforcement before/after unlock, actual microphone capture, Bluetooth/USB route quality, real phone-call recovery, lock-screen/background endurance, low-space exhaustion, long-session recovery loss bounds, battery/heat/memory, SpeechAnalyzer accuracy/time alignment, and Foundation Models inference quality. These require an authorized physical-device run; this assignment used the designated simulator and macOS host, without release signing.

The 30-second live segment interval is a nominal recovery design, not a measured crash-proof guarantee. Finalization temporarily needs disk space for both segments and the final original, and AAC concatenation decodes/re-encodes captured segments once. The provided sample text currently narrates to 88–105 seconds; original fixture content was preserved. AI citation validity is tested structurally, not as proof of semantic truth. Draft insights remain reviewable. No cloud fallback, public uploads, real trading, analytics, or enhancement implementation was added.

The ownership boundary was retained: core/package, project generation, scripts, support plist, and backend documentation were edited; Claude's app/views/components/asset catalog/source fixture/UI tests were not edited by Codex. Public additions and operational details are in `docs/prototype/CORE-NOTES.md`.

## Feature-complete core — incremental verification (2026-10-05)

Owned paths only; no commits, releases, dependency installation, or credential access. Server contract is read-only `docs/api/API.md` v1. All Simulator commands use `32502FB1-1CBE-4555-B1FE-CF1712B1A45C` and `build/DerivedData-core` through `scripts/dev.sh`.

- `scripts/dev.sh test > build/codex/step1-test.log 2>&1`: first attempt failed compilation on an overly complex DSP expression (exit 65); expression split. Rerun **passed**, 39 tests, exit 0. Covers finite limiter output, trim validation, immutable source checksum, provenance persistence, A/B anchoring.
- `scripts/dev.sh test > build/codex/step2-test.log 2>&1`: **passed**, exit 0; revision staleness/idempotency, unsupported language, existing capture/processing/store tests.
- `scripts/dev.sh test > build/codex/step3-test.log 2>&1`: **passed**, exit 0; saved location precision stripping/rounding. Live GPS/MapKit search not invoked in tests.

## Feature-complete core — final evidence (Sower, 2026-10-05)

Implemented the complete core brief in owned package/configuration/scripts/support/documentation paths. No commits, push, deploy, release signing, dependency installation, changes to server/web/UI sources, or access to existing external credentials. Other sessions' changes in those paths were left intact. `docs/build/BRAND.md` supplied the owner's Sower name/host; `docs/build/CORE-REQUESTS.md` supplied UI compatibility requests. Exact signatures and deviations are in `docs/prototype/CORE-NOTES.md`. API v1, including the server's additive reviewer fields, was read without modification.

Working capabilities: immutable Voice Focus derivatives, explicit trim windows, source-time level-matched A/B/revert, music hints and diagnostics; revisioned transcript editing with citation staleness and locale-bound speech/model processing; foreground venue suggestions with precision stripping; whole-library ZIP backup/merge and optional authenticated passphrase encryption; offline ES256 service/offer verification; recoverable P-256 identity with device-only Keychain and Secure Enclave at-rest protection when available; signed community requests, persistent cache/inbox/sync; explicit publishing with background file uploads/relaunch attachment/backoff/cancellation; discovery/keep/rights-gated streaming through the shared player; gifts/swaps/CAS/idempotent transitions/blocking/visible history/links/nearby; server packs and labelled bundled fallback, Atlas, journeys, reports; official master choice preserving source anchors; public PNG share links; build-setting brand name/scheme/bundle ID.

| Exact command | Outcome |
| --- | --- |
| `scripts/dev.sh test > build/codex/step4-test.log 2>&1` | Initial archive test failed one whole-second ISO date equality assertion. Changed the assertion to verify note identity/text, consistent with existing persistence precision. |
| `scripts/dev.sh test > build/codex/step4-5-test.log 2>&1` | Passed, 45 tests; backup merge/authentication/CRC/path checks and service-token signature/audience/expiry checks. |
| `scripts/dev.sh test > build/codex/step6-7-test.log 2>&1` | Initial generic nested-type/actor-isolation compiler errors corrected in subsequent run. Final compilation/testing is superseded by the full suite below. |
| `scripts/dev.sh test > build/codex/step8-test.log 2>&1` | Passed, 48 tests, including signing/recovery/offline cache/community merge. |
| `scripts/dev.sh test > build/codex/step10-14-test.log 2>&1` | Initial nearby invitation callback concurrency error fixed with a single-use MainActor callback wrapper. Rerun passed, 48 tests. |
| `scripts/dev.sh test > build/codex/aac-trim-before.log 2>&1` | The first real AAC fixture rendered successfully, so it did not reproduce the UI-reported padding bug. |
| `scripts/dev.sh test > build/codex/aac-padding-before.log 2>&1` | Reproduced: 49 tests, one failure, `Trim needs review`, after injecting a 40 ms container-duration excess on the real AAC asset at the public render seam. |
| `scripts/dev.sh test > build/codex/aac-padding-after.log 2>&1` | Passed, 49 tests; decoded-frame clamping/end tolerance fixed the reproduced failure. |
| `scripts/dev.sh test > build/codex/ui-bridge-test.log 2>&1` | Passed, 49 tests; shared-player bridge compiled with the package. |
| `scripts/dev.sh test > build/codex/publishing-tests.log 2>&1` | Passed, 51 tests; explicit confirmation/checklist/rights/trim gates, private-content exclusion, offline retry preserving job/idempotency identity. |
| `node scripts/core-server.mjs prepare > build/codex/core-prepare.log 2>&1` | Prepared ignored isolated config and newly generated local-only test secrets; no production secrets read. |
| `node scripts/core-server.mjs migrate > build/codex/core-migrate-final.log 2>&1` | Passed; isolated D1 migrations through `0002_review_context.sql`. |
| `node scripts/core-server.mjs dev > build/codex/core-server.log 2>&1` | Worker ready on **8788**, persisted to `build/wrangler-core`. Uses the existing server-owned Wrangler installation, no install/network dependency retrieval. Server session's 8787 process/state was never stopped or touched. |
| `TEST_SCHEME=SermonSetCoreIntegration scripts/dev.sh test > build/codex/local-integration-test.log 2>&1` | Initial runs blocked by local fixture setup (bootstrap Origin, escaped dotenv JSON, production-route Origin rewriting) and missing reviewed preacher/passage metadata. These were corrected in owned test/config/client files. |
| `TEST_SCHEME=SermonSetCoreIntegration scripts/dev.sh test > build/codex/local-integration-final.log 2>&1` | Passed, 53 tests including the complete native Worker journey. |
| `scripts/dev.sh test > build/codex/core-all-final.log 2>&1` and `scripts/dev.sh test > build/codex/core-unit-final.log 2>&1` | Intermediate hardening attempts failed compilation on an inaccessible private setter and overlapping optional-feature access. Both were corrected; these logs are failure evidence, not claimed passes. |
| `TEST_SCHEME=SermonSetCoreIntegration scripts/dev.sh test > build/codex/core-verified-final.log 2>&1` | Passed, 55 tests / 10 suites, after persistence/retry/official-cache hardening and additional link/music/cancellation checks. |
| `TEST_SCHEME=SermonSetCoreIntegration scripts/dev.sh test > build/codex/core-final-validation.log 2>&1` | **Final: passed, 55 tests / 10 suites, 19.003 seconds, exit 0, TEST SUCCEEDED.** Includes the final trim playback, metadata gates, and backup recovery changes. |
| `scripts/dev.sh build > build/codex/app-core-final.log 2>&1` | Passed, full app + core, exit 0. |
| `scripts/dev.sh run -SowerServer http://127.0.0.1:8788 -SermonSetPreviewData > build/codex/core-launch-final.log 2>&1` | **Final app build/install/launch passed**, exit 0; designated Simulator reported `com.gazhenko.sower: 84361`. Preview data, local server; no microphone or personal live-library use. |
| `bash -n scripts/dev.sh` | Passed, exit 0. |
| `node --check scripts/core-server.mjs` | Passed, exit 0. |
| `plutil -lint SermonSet/Support/Info.plist` | Passed, exit 0. Duplicate camera usage key removed while preserving the UI owner's wording. |
| `git diff --check -- Packages/SermonSetCore project.yml scripts SermonSet/Support docs/prototype/CORE-NOTES.md docs/REVIEW.md` | Passed, exit 0. |
| `/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' build/DerivedData-core/Build/Products/Debug-iphonesimulator/SermonSet.app/Info.plist` | `Sower`. |
| `/usr/libexec/PlistBuddy -c 'Print AppURLScheme' build/DerivedData-core/Build/Products/Debug-iphonesimulator/SermonSet.app/Info.plist` | `sower`. |
| `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/DerivedData-core/Build/Products/Debug-iphonesimulator/SermonSet.app/Info.plist` | `com.gazhenko.sower`. |

Native local-server evidence covers actual Apple P-256 → WebCrypto request signatures and fresh nonces, account registration/update-role fetch/deletion, reviewed metadata publication/moderation, keeping, repeated offer creation with one idempotency UUID, repeated gift accept and swap confirm, source library/note retention, server-issued offline offer/service verification, church claim/verified service issuance, uploading checksum-matched trimmed enhanced AAC, rights-checked issue/redemption, official supersession and explicit source-change acknowledgement with unchanged prior moment asset ID, PNG share upload/page, blocking/unblocking, reports, discover, packs/fallback, Atlas, and revoked/superseded audio rejection. This uses only newly generated accounts/churches/assets in the isolated test database. No tests touch existing app Keychain credentials; unit tests inject memory signers. The origin diagnosis used a throwaway wrapper under ignored `build/core-server`; it was removed and the final server imports the unmodified production entry point. No diagnostic instrumentation remains in production core.

The only final build/test warning is Apple's AppIntents metadata extraction notice (no AppIntents dependency). Some test logs contain Simulator audio HAL messages. There is no physical acoustic-quality claim.

**Blocked / not run on physical iPhone:** live GPS/MapKit results and denial UI, camera scans, two-device encrypted MultipeerConnectivity exchange/local-network permission, Secure Enclave/Keychain persistence and unlock/Data Protection enforcement, killed-app/background URLSession delivery, network handover, actual mic/Bluetooth/phone-call capture recovery, long-session thermal/storage/memory behavior, multilingual speech/model inference and semantic accuracy, perceptual Voice Focus quality and decoded AAC true-peak compliance. The background uploader and nearby delegates compile; their real process-death/radio behaviors require physical-device validation. UI journeys are Claude-owned and were not claimed by this core verification.

Material limits: ZIP v1 supports archives below 4 GB and optional AES-GCM wrapper below 512 MB; unsupported sizes fail explicitly without losing recordings. Backup includes saved library audio/artifacts, remote audio metadata and cards, but not unfinished capture manifests or account secrets. Recovery uses a recoverable software signing key protected at rest by an enclave agreement key, since an enclave-only signing key cannot be exported. Music detection is heuristic; silence is flagged as potential dropout, not proven device failure. Normalization targets −16 LUFS with gain bounds and a conservative cubic-interpolated limiter; limiting/codec behavior may lower level or alter reconstructed peaks. Upload resumption is at job/file level (immutable full PUT restart), because API v1 has no byte-range upload/resume-token renewal endpoint. Expired upload capabilities require a newly confirmed job. Official alignment remains explicitly unavailable; prior sources that are superseded/removed may not be remotely replayable, while personal originals remain available. Account-visible offer history and consent-suppressed coarse journeys are exposed; no endpoint provides unrestricted private cross-owner trade history.

Final result bundle: `build/logs-core/tests-20261005-115933-84589.xcresult`. The shared workspace still contains the other owners' in-progress changes; no clean-tree claim is made. To rerun locally without altering `server/`: `node scripts/core-server.mjs prepare`, `node scripts/core-server.mjs migrate`, `node scripts/core-server.mjs dev` in one terminal, then `TEST_SCHEME=SermonSetCoreIntegration scripts/dev.sh test` in another. Prepare regenerates only this isolated server's test keys, so retain that process/config across a single test run.

## Server local routing regression — 2026-10-05

`server/scripts/dev.mjs` strips production routes/custom_domain and workers_dev from its local config.
From `server/`: `node --test test/dev.test.mjs` reproduced the original HTTP 403 before the fix and
passed 1/1 after it; final `npm test` passed 41/41 in 44.65 s, exit 0; `npm run check` bundled the
production Worker and confirmed disabled observability, exit 0 (not a full TypeScript typecheck).
The real-wrapper regression uses port 8795 and isolated persistence under ignored
`build/wrangler-codex`; it preserves the existing listener on 8787. Exact fixture commands, initial
harness failures, coverage, and cleanup evidence are in [SERVER-NOTES.md](build/SERVER-NOTES.md#local-dev-strip-production-routes-2026-10-05).

## Required publishing details — CORE-REQUESTS §7 (2026-10-05)

`buildPublishRequest` now throws a `SermonSetError` listing all missing public fields in title, preacher, passage, kind order. Nil, empty, and whitespace/newline-only text is rejected. The request requires an explicit sermon kind and uses its raw value; it does not default to hope. Existing checklist, size, sample, audio, and rights gates remain in place. Validation preserves the stored sermon.

Changes for this task are confined to `Packages/SermonSetCore/Sources/SermonSetCore/Publishing.swift`, package `PublishingTests.swift` / `LocalServerTests.swift`, and the requested core notes/review documentation. Existing publishing fixtures explicitly select wisdom. No commits were made. The shared workspace had pre-existing changes, which were retained.

| Exact command | Outcome |
| --- | --- |
| `mkdir -p build/logs-core` | Passed, exit 0; logs stay under ignored workspace build output. |
| `SIM_UDID=32502FB1-1CBE-4555-B1FE-CF1712B1A45C DERIVED_DATA=build/DerivedData-core TEST_SCHEME=SermonSetCore scripts/dev.sh test > build/logs-core/publish-required-fields-test.log 2>&1` | **Passed**, exit 0, `TEST SUCCEEDED`; Swift Testing reported **58 tests in 11 suites**, 19.037 seconds. The local-server integration test was skipped because this unit scheme does not configure `SERMONSET_INTEGRATION_URL`. |
| `git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md` | Passed, exit 0. |

The test script generated the ignored Xcode project, built the core and test target with release signing disabled, and used only `build/DerivedData-core` and the designated, already-booted core Simulator. Its underlying test command was:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination platform=iOS\ Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C \
  -derivedDataPath build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261005-131331-6532.xcresult test
```

New Swift Testing coverage has three parameterized tests with 15 cases: each missing field individually (including kind with all other fields valid), all missing fields with nil/empty/whitespace text, and complete payloads preserving each of the eight supported kinds, trimmed preacher/passage, and unchanged local data. Existing privacy/checklist/audio and offline publishing queue tests also passed. The local-server fixture was updated for the new requirement but its network journey was not run by this command. This is Simulator core validation; no app/UI launch or physical-iPhone validation is claimed.

Full log: `build/logs-core/publish-required-fields-test.log`. Result bundle: `build/logs-core/tests-20261005-131331-6532.xcresult`.

## Server uppercase brand expectation (2026-10-05)

`server/test/dev.test.mjs` now expects `BRAND_NAME = "SOWER"`. The owner's existing
`server/wrangler.toml` remains byte-for-byte unchanged; server source/fixture/README auditing found
no other mixed-case brand expectation. Details are in
[SERVER-NOTES.md](build/SERVER-NOTES.md#uppercase-brand-expectation-2026-10-05).

Both commands ran from `server/` with existing dependencies:

| Exact command | Outcome |
| --- | --- |
| `npm test > ../build/wrangler-codex/brand-uppercase-npm-test.log 2>&1` | Passed, exit 0: 81/81 tests, 0 failures/cancellations/skips, 49.56 seconds. |
| `npm run check > ../build/wrangler-codex/brand-uppercase-npm-check.log 2>&1` | Passed, exit 0: Worker bundle compiled and observability disabled; not a full TypeScript typecheck. |

The real dev-wrapper regression used port 8795 and stopped its own process group. Port 8795 had
no listener afterward; port 8787 was not contacted or modified. No deployment, remote command,
dependency installation, commit, or changes to `web/`, `Packages/`, `SermonSet/`, or `site/`.

## Framework callback isolation — CORE-REQUESTS §8 (2026-10-05)

The live capture tap is now created by a nonisolated factory with an explicit Sendable closure. Eighteen other framework/worker callback sites have explicit Sendable annotations; controller state updates retain their main-actor hops. The complete call-site inventory and audit findings are in `docs/prototype/CORE-NOTES.md`. Changes are confined to five core source files, two core test files, and these two documentation files. Existing workspace changes were preserved; a start/end content comparison found no changes to `SermonSet/`, `web/`, `site/`, or `server/`. No commits, credentials access, signing, or dependency installation.

| Exact command (repository root) | Outcome |
| --- | --- |
| `scripts/dev.sh test -only-testing:SermonSetCoreChecks/CallbackIsolationTests > build/callback-isolation/red-test.log 2>&1` (first attempt, log subsequently moved to `harness-build-error.log`) | Exit 65: the new harness passed a variable String to `Issue.record`, which requires `Comment`; corrected to `Comment(rawValue:)`. This was a harness compilation failure. |
| `scripts/dev.sh test -only-testing:SermonSetCoreChecks/CallbackIsolationTests > build/callback-isolation/red-test.log 2>&1` (second attempt) | Exit 65: 59 tests / 12 suites ran; two duration assertions in the 44.1 kHz case failed because existing conversion latency shortened 0.4 s input by 0.0119375 s. The harness allowance became 25 ms for conversion, retaining one-frame tolerance for direct append. The script does not forward extra test arguments, so this ran the full suite. The available Simulator/toolchain did not reproduce the reported physical-device isolation trap after extracting the initial tap factory, before explicit nonisolated/Sendable annotations. This is not a red reproduction of that trap. |
| `scripts/dev.sh test > build/callback-isolation/core-test.log 2>&1` | **Passed**, exit 0, `TEST SUCCEEDED`: **59 tests in 12 suites**, 21.232 s. The tap regression passed both sample-rate cases; capture and playback notifications delivered from the background queue passed. The local-server integration test was skipped because this unit scheme does not configure `SERMONSET_INTEGRATION_URL`. |
| `xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO > build/callback-isolation/device-build.log 2>&1` | **Passed**, exit 0, `BUILD SUCCEEDED`; device product `build/codex-device/Build/Products/Debug-iphoneos/SermonSet.app`. No installation, launch, or release signing. |
| `git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md` | Passed, exit 0. |

The test script regenerated the ignored Xcode project and used the designated, already-booted SermonSet Core Simulator (iOS 26.5), without changing shared Simulator configuration. Compiler: Apple Swift 6.3.3, Swift 6 language mode. Its final underlying command was:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261005-204756-8916.xcresult test
```

Logs and snapshots are under ignored `build/callback-isolation/`; final result bundle is `build/logs-core/tests-20261005-204756-8916.xcresult`. Test logs include Simulator audio HAL/loudness diagnostics and expected offline URLSession failures. Both builds report Apple's no-AppIntents metadata notice. The device build also reports the existing UI `VenueSuggestions.swift:13` warning that `where` applies only to the second case pattern; the UI-owned file was not edited.

Physical-iPhone live microphone start/resume, realtime delivery, permission prompts, calls/Bluetooth routing, speech authorization, lock-screen remote commands, background URLSession process delivery, CoreLocation, and two-device Multipeer radio behavior were not run here. The supplied iPhone crash reports establish the original symptom; these Simulator tests and an unsigned device build do not claim a passing physical-iPhone check. Recording retention, copying, converter/file queue ownership, and existing capture/playback behavior remain unchanged.

## Automatic on-device summary — CORE-REQUESTS §9 (2026-10-05)

Implemented the exact summary models/store signatures and separate `ProcessingJobs.summary` state, persisted default-on preference, store-owned recording pipeline, foreground/relaunch recovery, iOS continued-processing bridge, chunk-note/hierarchical map-reduce generation, summary-only regeneration, editing/review/card use, and hand-written evidence-backed summaries for all eight sample sermons. Edited/accepted artifacts survive reruns, including edits made during inference and edited takeaways later marked draft. Earlier saved evidence remains attached to retained accepted text after a fresh transcription; acceptance does not set `isEdited`. Older libraries/takeaways/jobs decode without the new fields. The public API, prompt design, Info.plist requirements, and runtime limits are in [CORE-NOTES.md](prototype/CORE-NOTES.md#on-device-summary--core-requests-9-2026-10-05).

Source/API verification used the installed **iPhoneOS26.5.sdk**, rather than guessed FoundationModels/BackgroundTasks calls. `xcode-select -p` returned `/Applications/Xcode.app/Contents/Developer`; `xcrun --sdk iphoneos --show-sdk-path` returned `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk`. The interfaces read were `System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface` and `System/Library/Frameworks/BackgroundTasks.framework/Headers/{BGTaskRequest.h,BGTask.h,BGTaskScheduler.h,BackgroundTasks.apinotes}` beneath that SDK. They establish `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, model availability/locale/context, structured `LanguageModelSession.respond`, 26.4+ `tokenCount`, generation error cases, continued request `.fail`, default resources, dynamic registration exemption, task title/subtitle updates, `NSProgressReporting`, expiration and completion. Production generation has no network model or upload path.

Commands ran from the repository root with existing tools/dependencies. Output stays in ignored `build/summary`, `build/logs-core`, `build/DerivedData-core`, and `build/codex-device`. All test invocations use the required `scripts/dev.sh test` with stdout/stderr redirected for retained logs:

| Exact command | Outcome |
| --- | --- |
| `scripts/dev.sh test > build/summary/core-test-initial.log 2>&1` | Passed, exit 0: 59 tests / 12 suites, 18.735 s, `TEST SUCCEEDED`. Initial implementation, existing tests. |
| `scripts/dev.sh test > build/summary/core-test-with-fixtures.log 2>&1` | Exit 65: new test harness compilation failed on the FoundationModels/core `Transcript` name collision. Qualified the core type. |
| `scripts/dev.sh test > build/summary/core-test-fixtures-2.log 2>&1` | Exit 65: the fixture transcript expression exceeded the compiler's type-checking limit. Split into typed locals. |
| `scripts/dev.sh test > build/summary/core-test-fixtures-3.log 2>&1` | Exit 65: 68 tests / 13 suites ran, 19.464 s; two assertions failed. Reduction cache keys varied with JSON key order, and NLTagger missed an invented proper-name phrase. Sorted prompt JSON and added a source check for capitalized multiword names. |
| `scripts/dev.sh test > build/summary/core-test-fixtures-4.log 2>&1` | Passed, exit 0: 68 tests / 13 suites, 19.419 s. |
| `xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO > build/summary/device-build-initial.log 2>&1` | Passed, exit 0, `BUILD SUCCEEDED`. |
| `scripts/dev.sh test > build/summary/core-test-final.log 2>&1` | Exit 65: additional regression harness hit a Swift Testing macro/rethrows issue with a key-path predicate. Replaced it with an explicit closure. No production compilation error. |
| `scripts/dev.sh test > build/summary/core-test-final-2.log 2>&1` | Passed, exit 0: 70 tests / 13 suites, 19.180 s. Includes historical-source retention and edits during inference. |
| `xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO > build/summary/device-build-final.log 2>&1` | Passed, exit 0, `BUILD SUCCEEDED`. |
| `scripts/dev.sh test > build/summary/core-test-verified.log 2>&1` | Passed, exit 0: 70 tests / 13 suites, 19.397 s. Includes immediate scheduler expiration-handler setup and cached-evidence validation. |
| `xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO > build/summary/device-build-verified.log 2>&1` | Passed, exit 0, `BUILD SUCCEEDED`. |
| `scripts/dev.sh test > build/summary/core-test-complete.log 2>&1` | **Final: passed**, exit 0: **70 tests / 13 suites**, 19.505 s, `TEST SUCCEEDED`. Final edit-retention and older-takeaway decoding coverage. |
| `xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO > build/summary/device-build-complete.log 2>&1` | **Final: passed**, exit 0, `BUILD SUCCEEDED`; core and app target compiled successfully. |
| `git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md` | Passed, exit 0. |
| `xcrun swiftc --version` | Apple Swift 6.3.3; Swift 6 language mode used by the project/package. |

The eleven new fixture tests drive the production map/reduce adapter through an injected deterministic client, without claiming real model inference. They cover long transcripts requiring multiple reduction levels, source-order restoration, low-confidence flags, cache reuse/invalidation, guardrail/context-skipped chunks, reduction cancellation and checkpoint reuse, final reduction failure retaining takeaways, invalid citations/invented speech/scripture/name rejection, single-sentence/word-limit/open-question shape, summary editing/review/card copying and durable reopen, summary-only artifact retention, full-regeneration edit preservation, no-model fallback, preference persistence, canceled/duplicate awaiting callers, speech checkpoint/relaunch recovery, transcript correction/rebased evidence, historical evidence retention, edits during inference, valid older-library/job/takeaway decoding, and all sample summaries. Existing 59 tests remain passing. The local-server integration test remains skipped in the unit scheme because it does not configure `SERMONSET_INTEGRATION_URL`.

The script regenerates the ignored Xcode project and uses the designated, already-booted SermonSet Core Simulator (iOS 26.5) without changing its configuration. Unsigned device compilation produced `build/codex-device/Build/Products/Debug-iphoneos/SermonSet.app`; it did not install or launch on an iPhone. Logs include the existing no-AppIntents metadata notice and Simulator audio diagnostics. The first app build also compiled the existing UI-owned `VenueSuggestions.swift:13` case-pattern warning; it was not edited.

**Blocked here / physical iPhone validation required:** real Apple Intelligence semantic quality over a 30–50 minute recording, speech asset/permission states, continued-processing admission/live activity/progress while backgrounded or locked, system/user expiration, force-quit/relaunch behavior, and long-session thermal/battery/memory behavior. Fixture success and unsigned device compilation establish no physical-device inference or background-execution claim. The UI owner must add `BGTaskSchedulerPermittedIdentifiers = [com.gazhenko.sower.process.*]` and `UIBackgroundModes` containing `processing` (retaining `audio`). Missing keys or scheduler rejection use foreground processing plus durable checkpoint resume; there is no entitlement/signing bypass or fabricated summary fallback.

Edits made by this task are confined to `Packages/SermonSetCore` and the two requested documentation files. No commits, pushes, deployment, release signing, credentials access, dependency installation, or edits by this agent to `SermonSet/`, `project.yml`, `web/`, `site/`, or `server/`. A protected-path start/end content snapshot under `build/summary` detected concurrent UI/site owner changes (including the new summary UI); those changes were retained and were not made or reverted by this agent. The workspace already had extensive uncommitted owner changes at task start.

Final result bundle: `build/logs-core/tests-20261005-212936-20820.xcresult`. The final script-expanded test command was:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261005-212936-20820.xcresult test
```

## Automatic speech asset preparation — CORE-REQUESTS §10 (2026-10-05)

`processRecording` now opts into speech asset preparation inside the existing transcription stage. When the selected-language adapter reports `.needsDownload`, the job remains `.running(progress: nil)` while `prepareSpeechAssets(using:)` awaits installation. The stage rechecks that adapter's availability, resumes transcription progress, and continues to insights/summary. The public manual transcription and preparation APIs retain their behavior. Unsupported/unready states use the existing `.unavailable` reasons; preparation errors use the existing `.failed` reporting and retain the pending retry marker and original audio.

| Exact command (repository root) | Outcome |
| --- | --- |
| `scripts/dev.sh test > build/speech-assets/core-test.log 2>&1` | **Passed**, exit 0, `TEST SUCCEEDED`: **76 tests in 14 suites**, 19.407 s. The local-server integration test was skipped because the unit scheme does not configure `SERMONSET_INTEGRATION_URL`. |
| `git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md` | Passed, exit 0. |

Six new fixture tests (eight cases) cover indeterminate progress during asynchronous preparation, summary completion, the retained selected transcript locale, download failure/readable error/audio retention/retry, unsupported locales, availability rechecks after preparation, explicit manual preparation, and skipping installation for available assets or an existing transcript. These tests use a fake speech adapter and deterministic summary client; no real Apple assets were downloaded. Physical-iPhone asset installation and first-recording summary behavior were not run here.

The script regenerated the ignored Xcode project and used the designated, already-booted SermonSet Core Simulator without changing its configuration. Build output, baseline snapshots, logs, and result bundles remain under ignored `build/`. The script-expanded command was:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261005-213659-23331.xcresult test
```

Changes are confined to core `Processing.swift`, `RecordingProcessing.swift`, the new `RecordingSpeechAssetsTests.swift`, and the two requested notes files. The task baseline comparison found no changes to `SermonSet/`, `project.yml`, `web/`, `site/`, or `server/`. Existing owner changes were preserved. No commits or dependency installation. Full log: `build/speech-assets/core-test.log`; result bundle: `build/logs-core/tests-20261005-213659-23331.xcresult`.

## CORE-REQUESTS §11 — Sermon Notes (Codex core, 2026-10-07)

Implemented the requested `SermonNotes` / `SermonPoint` / `KeyPhrase` contract, optional persisted notes/reason fields, notes-only regeneration and edit/review/card APIs, observable stage detail, on-device engine boundary, token-sized structural map/reduce pipeline, evidence/phrase/scripture validation, retries/checkpoints, DEBUG trace/regeneration launch arguments, and eight hand-written sample note fixtures. Existing summary API/types still compile and are deprecated. The live notes path replaces legacy summary reduction; legacy deterministic summary adapters and tests remain supported. The UI handoff and full API/behavior notes are in `docs/prototype/CORE-NOTES.md`, section “Sermon Notes — CORE-REQUESTS §11”.

Read the installed iOS 26.5 FoundationModels Swift interface directly (no network/dependencies):

```sh
xcode-select -p
xcrun --sdk iphoneos --show-sdk-path
rg -n 'tokenCount|contextSize|GenerationOptions|temperature|SamplingMode|respond\(|GenerationError|GenerationSchema|permissiveContent|public init\(' /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface
sed -n '587,640p' /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface
```

Confirmed real `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, `tokenCount(for: Prompt/Instructions/GenerationSchema)`, `contextSize`, fresh `LanguageModelSession.respond(to:generating:options:)`, and `GenerationOptions(temperature:maximumResponseTokens:)`. Token counting requires iOS/macOS 26.4; earlier systems return a notes-unavailable reason and retain their other processing behavior.

Final required test command:

```sh
scripts/dev.sh test
```

**PASS, exit 0: 86 Swift Testing tests in 15 suites, 29.340 seconds; `TEST SUCCEEDED`.** The script regenerated the ignored Xcode project and used the already-booted dedicated `SermonSet Core (Codex)` iOS 26.5 simulator `32502FB1-1CBE-4555-B1FE-CF1712B1A45C`. No shared simulator was reset or modified. Exact expanded test invocation:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination platform=iOS\ Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261007-082852-69203.xcresult test
```

Final stdout/stderr: `build/notes-test-final5.log`; result bundle: `build/logs-core/tests-20261007-082852-69203.xcresult`. New tests cover cue forms/order/spacing/non-point roles, cleaning/times, token budgets and middle coverage, every requested leaked string, exact source phrases/scripture, ordering and announced-N enforcement, evidence fallback, higher-temperature/split/skip retries, checkpoint reuse/cancellation/hash invalidation, legacy summary decoding, sample fixtures, and store acceptance/edit/review/card/concurrent-edit preservation. The existing library migration test now removes only the new insights `notes` field when making a pre-notes fixture, preserving the older required personal-notes dictionary.

Final required unsigned device build command:

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device CODE_SIGNING_ALLOWED=NO
```

**PASS, exit 0: `BUILD SUCCEEDED`.** Log: `build/notes-device-final5.log`. No app/API integration failure remained at this build's snapshot of Claude's concurrent UI work. Expected legacy-summary deprecation warnings remain until callers migrate.

Iteration outcomes (same test/build commands, separate ignored logs): `build/notes-test-initial.log` failed compilation on an actor-isolated trace default, corrected with a nonisolated immutable prompt version. `build/notes-test-second.log` was intentionally interrupted with `kill -INT 64907` after the legacy summary fixture stalled while entering the new system-model path; legacy fixture clients now stay isolated from real inference, and unavailable system-model capability is reused within the pipeline. `build/notes-test-final.log` failed compilation on an ambiguous FoundationModels/core `Transcript` test type; explicitly qualified. `build/notes-test-final2.log` failed on capitalized filler cleaning and an overbroad legacy-fixture field removal; fixed. `build/notes-test-final3.log` failed on a key phrase retaining a leading filler and a test using a stale draft takeaway ID after regeneration; exact source spans now prefer the shortest normalized match, and the test reads the current artifact. All issues were covered by the final passing full run. Earlier unsigned device builds also passed (`build/notes-device-initial.log`, `build/notes-device-final.log`, `build/notes-device-final3.log`, `build/notes-device-final4.log`). The preceding full run (`build/notes-test-final4.log`) also passed all 86 tests. Final review then separated notes-job completion from retained legacy-summary completion, added a regression assertion for unavailable notes with an accepted legacy summary, and enforced the requested two-sentence map summary. The final5 test/build logs above validate these final changes. `git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md` passed.

Physical iPhone validation was not performed. Simulator tests use a deterministic notes client and do not establish Apple Intelligence notes quality, actual tokenization/inference timing, locked/background execution, or DEBUG trace extraction on the owner's iPhone. The unsigned device build establishes SDK/app compilation only. No signing, credentials, commits, pushes, deployments, dependency installation, or direct edits to `SermonSet/`, `project.yml`, `web/`, `site/`, or `server/` were performed. Changes are limited to core implementation/tests and the two requested documentation files; generated output remains under ignored `build/` and the ignored generated Xcode project.

## CORE-REQUESTS §12 — optional local Qwen engine (Codex, 2026-10-07)

Scope: added `Packages/SermonSetLocalModel` with the pinned MLX dependency, model configuration/manifest, background download manager, local-only Qwen engine, lenient JSON parser, and DEBUG comparison/startup hook. Core changes expose the existing preparation/validator and model DTOs, persist/select the notes engine with an Apple fallback reason, and report comparison token-count provenance. Tests cover JSON repair, download/cellular/disk/integrity/resume/relaunch/delete states, whole/sectioned inference through a fake runtime, checkpoint reuse/invalidation, grounding and provenance, unload on failure/cancellation, comparison without saving notes, and engine-choice persistence/fallback. Existing listener edits, transcripts, and recordings remain protected by the existing store behavior.

Only Packages/ and the two requested documentation files were edited for this slice. SermonSet/, project.yml, web/, site/, server/, and coordinator sources were not edited. The workspace already contained substantial owner/UI/core changes; those were retained. No commits, pushes, signing, credentials, or shared Simulator changes. The designated Core Simulator was already booted. Scratch clones, logs, build output, and new package fixtures are under ignored `build/`, `.build/`, or `.swiftpm/` directories. Claude's exact XcodeGen package/product addition and app lifecycle wiring are in `docs/prototype/CORE-NOTES.md`.

Environment: Xcode **26.6 (17F113)**; Apple Swift **6.3.3**, arm64 macOS 26; iOS SDK **26.5**. `SermonSetCore/Package.swift` remains dependency-free.

### Dependency/API verification before implementation

```sh
git ls-remote --tags https://github.com/ml-explore/mlx-swift-lm.git
git clone --depth 1 --branch 2.31.3 https://github.com/ml-explore/mlx-swift-lm.git build/local-model-api/mlx-swift-lm
swift package --package-path Packages/SermonSetLocalModel resolve
```

PASS (exit 0). Resolution log: `build/local-model-api/resolve.log`. Read the resolved checkout's actual `Package.swift`, `LLMModelFactory.swift`, `Models/Qwen35.swift`, `ModelFactory.swift`, `ModelContainer.swift`, `UserInput.swift`, `Evaluate.swift`, and tokenizer loader, plus the corresponding transitive tokenizer API. Pin **2.31.3**, commit **25b00d4e22e61ec9c41efda47990cd2084ec87ff**, includes text Qwen35 and the `qwen3_5` registration. New `Package.resolved` records all transitive revisions. Read pinned Hugging Face metadata/config for revision **32f3e8ecf65426fc3306969496342d504bfa13f3**, sizes, license, and SHA-256 values without downloading the model weights.

### Final checks

From the repository root:

```sh
scripts/dev.sh test
```

PASS (exit 0): **89 tests in 16 suites**, 30.591 seconds, including the three new `NotesEngineChoiceTests`. Result bundle: `build/logs-core/tests-20261007-090140-88267.xcresult`; captured output: `build/local-model-api/dev-test-final.log`. The script's exact underlying test command was:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261007-090140-88267.xcresult test
```

```sh
swift build --package-path Packages/SermonSetLocalModel
swift test --package-path Packages/SermonSetLocalModel
```

PASS (both exit 0). Build log: `build/local-model-api/local-build-final.log` (2.78 seconds). Tests: **12 tests in 3 suites**, 0.406 seconds; log: `build/local-model-api/local-tests.log`. Tests use fake transport/inference and small generated fixtures; they do not download weights or claim GPU/model success. Engine fixture tests are serialized to match the implementation's deliberate one-run-at-a-time admission gate. Initial parallel fixture attempts hit that gate; serialization corrected the test setup. The comparison fixture decoder was corrected to match the trace encoder's ISO-8601 dates before the passing final run.

From `Packages/SermonSetLocalModel`, complete arm64 iOS build attempt:

```sh
xcodebuild -scheme SermonSetLocalModel -destination 'generic/platform=iOS' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-local-model -clonedSourcePackagesDirPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/SourcePackages-local-model -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
```

**BLOCKED / build failed (exit 65)**: `cannot execute tool 'metal' due to missing Metal Toolchain`. Log: `build/local-model-api/ios-build-complete-final.log`. MLX requires compilation of its Metal shader library. Xcode suggests `xcodebuild -downloadComponent MetalToolchain`; it was not run because this task authorizes the MLX package exception, not changing the installed Xcode toolchain. No full device build pass is claimed.

A separate diagnostic build verified the device Swift branches while omitting unavailable shader compilation:

```sh
xcodebuild -scheme SermonSetLocalModel -destination 'generic/platform=iOS' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-local-model -clonedSourcePackagesDirPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/SourcePackages-local-model -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO EXCLUDED_SOURCE_FILE_NAMES='*.metal' build
```

PASS for **arm64 iOS Swift/native source compilation only** (exit 0); log: `build/local-model-api/ios-swift-check-final.log`. The omitted shaders make this diagnostic artifact unsuitable for inference. This is distinct from the blocked complete package build and from physical iPhone validation.

```sh
git diff --check
```

PASS (exit 0).

### Tooling failures and exact workarounds

The initial generic-iOS command above without `-skipPackagePluginValidation` or `ENABLE_CODE_COVERAGE=NO` stopped at Xcode's `CudaBuild` plugin trust check (exit 65; `build/local-model-api/ios-build.log`). Read the resolved `mlx-swift/Plugins/CudaBuild/plugin.swift`: `isCudaEnabled()` is false on Apple platforms and returns no build commands. The owner-approved dependency is trusted only through the invocation-local `-skipPackagePluginValidation` option; no global Xcode trust preference was modified.

Adding only `-skipPackagePluginValidation` hit a **Swift compiler crash** emitting `CommunityPlaybackController`'s existing isolated destructor while code coverage was enabled (`MapRegionCounters`/`SILProfiler` stack; exit 65; `build/local-model-api/ios-build-plugin-reviewed.log`). `CLANG_ENABLE_CODE_COVERAGE=NO GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO GCC_GENERATE_TEST_COVERAGE_FILES=NO` did not disable Swift's coverage and reproduced the crash (`ios-build-final.log`). The actual Swift build setting is **ENABLE_CODE_COVERAGE=NO**, verified against the installed Xcode `Swift.xcspec`; this avoided the crash without changing the existing core class. A `build -enableCodeCoverage NO` attempt was rejected because that flag requires a testing action (`ios-build-no-coverage.log`). The following alternative accepted the flag, passed the core compiler stage, then reached the same missing-Metal blocker (`ios-build-for-testing.log`, exit 65):

```sh
xcodebuild -scheme SermonSetLocalModel -destination 'generic/platform=iOS' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-local-model -clonedSourcePackagesDirPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/SourcePackages-local-model -skipPackagePluginValidation -enableCodeCoverage NO CODE_SIGNING_ALLOWED=NO build-for-testing
```

### Remaining physical/environment checks

Blocked here: complete Metal-enabled iOS build until the Metal Toolchain is available; full 3.05 GB model download and OS-managed background/cellular resume; real Qwen/Apple quality comparison on the owner's sermon; instantaneous device peak/jetsam behavior; signed optional increased-memory entitlement and its grant under free Personal Team provisioning; locked/background GPU inference. Core Simulator tests, macOS fixture tests, and device-source compilation do not establish any of these as passing. The DEBUG trace reports actual MLX token counters, explicitly labeled Foundation Models re-tokenized transcript counts, and sampled process peaks; missing measurements remain unavailable. No default-engine change was made before the owner compares real notes.

## CORE-REQUESTS §13 — repair/degrade Sermon Notes (2026-10-08)

Implemented Apple `sermon-notes-v2`: field-level map repair, smaller schema/response reservation, token-budget and exact-generation-error diagnostics, distinct recursive-overflow and transformation-refusal recovery, extractive section notes, reduction of recovered sections, and deterministic partial notes when reduction fails. Added shared spoken-scripture detection to Apple and Qwen whole/map/reduce prompts; Qwen checkpoints use `qwen35-sermon-notes-v2`. Added discussion support and allowed editing phrase-only partial points without losing their evidence. Details are in `docs/prototype/CORE-NOTES.md`, §13.

Changes made by this task are confined to `Packages/` and these two documentation files. Existing owner changes were retained. No direct edits to `SermonSet/`, `project.yml`, `web/`, `site/`, `server/`, or coordinator sources; no commits, pushes, deployment, signing, credentials access, model downloads, or toolchain installation. Dependency manifests/pins were unchanged. Xcode materialized its already-cached dependency graph; package tests disabled automatic resolution/remote updates. The requested development script regenerated the ignored Xcode project and booted the designated Core simulator; shared simulators were not changed. New regression fixtures and diagnostic/build artifacts stay under ignored package `.build/` or repository `build/` directories.

### Final verification (repository root)

```sh
scripts/dev.sh test > build/notes-v2/dev-test.log 2>&1
scripts/dev.sh test > build/notes-v2/dev-test-final.log 2>&1
```

**Full suite BLOCKED**, both runs stalled in the existing `AudioTests.playbackSeekRateCompletionAndCaptureHandoff()` while `PlaybackController.load` calls `AVAudioPlayer.prepareToPlay`. A read-only runner sample shows waiting in Apple's audio queue/IO locks. These were stopped, not reported as passing (wrapper exit 143 after termination). Samples/logs: `build/notes-v2/simulator-stall.sample`, `dev-test.log`, `dev-test-final.log`. First run result path: `build/logs-core/tests-20261008-233721-43118.xcresult`; interrupted bundles are not successful test evidence.

A direct run excluding that case reached another existing playback call in `VoiceFocusTests.derivativePreservesOriginalAndAnchors()` at line 54 and stalled in the same Apple `prepareToPlay` path. It was also stopped. Evidence: `build/notes-v2/core-filtered.log`, `voice-focus-stall.sample`. No playback implementation or shared simulator/audio service was changed to bypass these failures.

Final remaining-suite command:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug \
  -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' \
  -derivedDataPath build/DerivedData-core -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath build/notes-v2/core-final.xcresult \
  '-skip-testing:SermonSetCoreChecks/AudioTests/playbackSeekRateCompletionAndCaptureHandoff()' \
  '-skip-testing:SermonSetCoreChecks/VoiceFocusTests/derivativePreservesOriginalAndAnchors()' test \
  > build/notes-v2/core-final.log 2>&1
```

**PASS, exit 0: 94 tests in 17 suites, 26.519 seconds; `TEST SUCCEEDED`.** Both new notes suites pass on iOS Simulator. This is a filtered run; the two audio cases remain blocked. The existing local-server integration case requires `SERMONSET_INTEGRATION_URL` and is not integration-server validation.

```sh
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update \
  > build/notes-v2/local-tests-final2.log 2>&1
```

**PASS, exit 0: 13 tests in 3 suites, 0.730 seconds.** Includes whole/map/reduce spoken-reference prompts, missing-passage fallback, shared smaller map schema, existing grounding/checkpoints/download/comparison behavior, and unload/cancellation fixtures. Uses fake inference/transport, with no model download or GPU inference claim.

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' \
  -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO > build/notes-v2/device-build-final.log 2>&1
```

**PASS, exit 0: `BUILD SUCCEEDED`.** The same exact command also passed before final review (`build/notes-v2/device-build.log`). This is a complete unsigned app/device build; the initial build compiled MLX Metal sources and linked its shader library, with no shader exclusions or extra build-setting workaround. The earlier §12 missing-Metal build blocker did not recur in this environment. No physical iPhone launch/inference, signing, or model quality is established by this build.

### Reproduction and privacy-preserving local replay

```sh
swift test --package-path Packages/SermonSetCore --filter NotesTests > build/notes-v2/baseline-core.log 2>&1
swift test --package-path Packages/SermonSetCore --filter NotesRepairTests > build/notes-v2/repair-red.log 2>&1
swift test --package-path Packages/SermonSetCore --filter Notes > build/notes-v2/core-focused4.log 2>&1
swift test --package-path Packages/SermonSetCore --filter NotesRepairTests > build/notes-v2/core-repair-final.log 2>&1
swift run --package-path build/notes-v2/replay Replay \
  build/device-data/0BE75C40-4C65-46F4-9801-B024F3030121-1791516222097.json \
  > build/notes-v2/replay-final.log 2>&1
```

Baseline: 10 original notes tests passed. The first synthetic repair regression failed because useful section output returned nil; it passed after repair. Focused iteration passed 22 tests in 5 suites; final repair-only run passed all 7 tests in 2.165 seconds. The final filtered simulator suite above verifies all final changes. Synthetic tests cover non-verbatim phrases, junk scripture, field/rule diagnostics, divine/transcript names, recursive overflow down to 600 tokens, middle refusal, every-section guardrail recovery, zero usable sections, reduce failure, discussion evidence, partial editing, and spoken/ASR references.

The ignored replay harness reads the private file at runtime and never emits source/model text. Before repair, **0/8** recorded map attempts survived; after repair, **8/8** survive. Full fake-model pipeline replay retains **4 model notes + 6 extractive notes**, covers **277/277** cleaned sentences, invokes reduction, and assembles partial notes after an intentionally injected reduce decoding error. This is local pipeline/repair verification against captured outputs; no new real-model run is claimed. No private transcript or raw output was copied into repository source, tests, or docs.

Diagnostic iteration failures: stale tests initially expected whole-result rejection and skipped sections; updated to the requested partial/extractive behavior. A large inline synthetic expression exceeded Swift's type-checking budget; split into smaller expressions. Parser tests exposed an ungrouped Psalm alias; corrected. A single-name NLTagger rejection assertion was replaced with an explicit unheard full-name fixture. Two attempts to pass exclusions through `scripts/dev.sh test` were ineffective because the wrapper drops extra arguments; those runs stalled and were terminated (exit 143), with logs `dev-test-without-stalled-playback.log` and `dev-test-filtered-final.log`. The wrapper was not edited. Xcode test enumeration confirmed the exact Swift Testing identifier, including `()`, and the successful filtered run invoked Xcode directly.

Read-only diagnostic commands included `sample 45588 3 -file build/notes-v2/simulator-stall.sample` and `sample 47939 2 -file build/notes-v2/voice-focus-stall.sample`. Stalled task-owned processes were terminated using `kill -INT 43518`, `kill -TERM 45588 43518`, `kill -TERM 46760 46395`, `kill -TERM 47238 47075`, `kill -TERM 47770 47607`, and `kill -TERM 47939 47860`. The first runner had already exited by the subsequent termination attempt. No shared simulator was reset or shut down.

```sh
git diff --check -- Packages docs/prototype/CORE-NOTES.md docs/REVIEW.md
```

PASS, exit 0. Remaining checks: the two blocked simulator playback cases, physical-iPhone regeneration with v2 prompts, new real Apple/Qwen notes quality, actual device context/token behavior, and locked/background inference. The supplied real-device trace plus fake replay is distinct from new device validation.


## Section 14 — Speech package review (2026-10-10)

Scope: Packages/ plus this review and CORE-NOTES. No app-source, project.yml, web/site/server changes or commits. Existing worktree changes were retained. Core remains dependency-free. Delivered SermonSetSpeech depends on FluidAudio **exact 0.17.7 with `traits: []`**. The real API reference and compiled validation dependency was the supplied offline checkout `build/asr-lab/FluidAudio` at `fc8c3e4f5103bf63a242453566525272e143a054`. No dependency installation, network model download, credential access, simulator reset, or release signing was performed.

### Offline speech dependency validation

To exercise the new package without resolving a remote dependency, the new manifest was temporarily pointed at the already-present checkout. The actual commands were:

```sh
mkdir -p build/speech-validation
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
Path('build/speech-validation/Package.swift.pinned').write_text(p.read_text())
p.write_text(p.read_text().replace(
    '.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: [])',
    '.package(path: "../../build/asr-lab/FluidAudio", traits: [])'))
PYCODE
swift test --package-path Packages/SermonSetSpeech > build/speech-validation/tests-verified.log 2>&1
```

**PASS, exit 0**. Swift Testing reports 14 tests in six suites, with the opt-in real-model test explicitly skipped when environment paths are absent: 13 executed unit/integration tests. Coverage includes word/subtoken confidence, punctuation and 30-second segmentation, speaker changes/greatest-overlap assignment, silence-aware primary speaker, supported/unsupported languages, memory/thermal fallback, selected locale hint, progress/offset propagation, download pause/resume/cancel/delete/cellular policy, nested file installation, backup exclusion, disk/integrity failure, manifest completeness, and comparison trace correctness/nonmutation/error recording.

For the actual cached model run, fixture setup and the command were:

```sh
python3 - <<'PYCODE'
from pathlib import Path
root = Path.cwd() / 'build/speech-validation/models'
root.mkdir(parents=True, exist_ok=True)
cache = Path.home() / 'Library/Application Support/FluidAudio/Models'
for name in ['parakeet-ultra', 'speaker-diarization']:
    if not (root / name).exists():
        (root / name).symlink_to(cache / name, target_is_directory=True)
(root / 'verified-ultra-diarization-v1').write_text('Cached public models; offline validation only\n')
PYCODE
SERMONSET_SPEECH_MODEL_DIR="$PWD/build/speech-validation/models" SERMONSET_SPEECH_AUDIO="$PWD/build/asr-lab/data/ami-sdm-long/ami-sdm-long.wav" swift test --package-path Packages/SermonSetSpeech > build/speech-validation/tests-cached-final.log 2>&1
```

**PASS, exit 0**, all 14 tests in six suites, **10.610 s** (warm Core ML caches). Real Ultra + offline diarization processed the supplied public 4.6-minute far-field AMI file: **79 finalized sentence segments, five anonymous speakers, 160 progress callbacks**. The test verifies bounded/final time ranges, finite confidence, speakers, primary speaker, and progress; it prints aggregate diagnostics, not transcript text. This run does not remeasure WER; ASR-EVALUATION remains the quality evidence. The earlier cold run successfully exercised the real models in 35.776 s, but its separate comparison-fixture test failed because an AVAudioFile writer had not closed before import; the writer is now scoped/closed and both ordinary and cached final suites pass. The earlier first/second package compile checks also exposed the iOS-only memory API on macOS, a FluidAudio module/type-name collision, and Swift 6 concurrency around `vm_page_size`; all were corrected with a platform-specific host-memory helper, the real converter type, and `host_page_size`.

After all offline package/device checks completed, the delivered dependency pin was restored and inspected without resolution:

```sh
cp build/speech-validation/Package.swift.pinned Packages/SermonSetSpeech/Package.swift
swift package --package-path Packages/SermonSetSpeech dump-package > build/speech-validation/delivered-manifest.json
```

**PASS, exit 0**. Dumped requirement is exact `0.17.7`, remote URL is `https://github.com/FluidInference/FluidAudio`, and its traits list is empty. **BLOCKED: clean remote 0.17.7 resolution/build**, because this task's working agreement prohibits requiring network access or installing dependencies. The source/API build evidence above is explicitly against the supplied checkout, not a fabricated release-resolution result.

### Core tests

```sh
scripts/dev.sh test > build/speech-validation/dev-test-verified.log 2>&1
```

**PASS, exit 0**, **106 tests in 18 suites**, **29.210 s**. The wrapper generated the ignored Xcode project, found its already-booted task simulator, and ran:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261010-124330-76292.xcresult test
```

Earlier full iterations passed 104 and 105 tests while regression coverage was added. Final focused verification, including the final bare-numbered-book contextual-string case, was:

```sh
swift test --package-path Packages/SermonSetCore --filter 'TranscriptionEngineTests|TranscriptEditingTests|ProcessingTests' > build/speech-validation/core-verified.log 2>&1
```

**PASS, exit 0**, **25 tests in three suites**, **1.211 s**. New Core coverage verifies persisted/default engine choice, fallback/readiness changes, actual-engine stamping, retranscription revision retention and note regeneration, retained moments/personal notes, evidence rebasing/changed-source review, exact-duplicate Apple finals without deleting overlaps, old-document decoding, known sermon context including `1 John` without a chapter, and monotonic batch/checkpoint progress. Initial Core compiler iterations failed while integrating the repository's actual domain field names and while a source was still being edited during a build; the final checks above compile and pass.

### Unsigned device builds

The exact requested command, after the final Core changes:

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/speech-validation/app-device-verified.log 2>&1
```

**PASS, exit 0, BUILD SUCCEEDED.** This current app build compiles Core and the existing LocalModel dependency; it does not yet link SermonSetSpeech because Claude's project.yml/app integration is still required. No app-source or project.yml changes were made to obtain this result.

An isolated ignored XcodeGen framework project also compiled and linked SermonSetSpeech/FluidAudio for the actual iOS device SDK using the local checkout. The generated spec at `build/speech-validation/project.yml` names `SpeechDeviceChecks`, uses iOS deployment 26.0, has a local `SermonSetSpeech` package reference, a framework target with `DeviceChecks.swift` containing `import SermonSetSpeech`, a dependency on the `SermonSetSpeech` product, `GENERATE_INFOPLIST_FILE: YES`, and Swift 6.0. Exact generation/build commands:

```sh
/opt/homebrew/bin/xcodegen generate --spec build/speech-validation/project.yml > build/speech-validation/generate-device.log 2>&1
xcodebuild build -project build/speech-validation/SpeechDeviceChecks.xcodeproj -scheme SpeechDeviceChecks -destination 'generic/platform=iOS' -derivedDataPath build/codex-speech-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/speech-validation/speech-device-delivery.log 2>&1
```

**PASS, both exit 0, BUILD SUCCEEDED.** No NeMo binary or package plugins were required. The final isolated device build used the temporary local dependency override described above, before restoring the delivered exact release pin.

### Handoff and remaining validation

Exact Claude additions to the existing project.yml mappings (also in CORE-NOTES):

```yaml
# Add beneath packages:
  SermonSetSpeech:
    path: Packages/SermonSetSpeech

# Add beneath targets.SermonSet.dependencies:
      - package: SermonSetSpeech
        product: SermonSetSpeech
```

Claude must retain `SpeechModelManager`, call `install(in: store)` immediately after store creation, refresh capabilities after model state changes, wire the Settings engine/model controls and transcript speaker labels/retranscribe action, invoke `try await speechModels.runLaunchArguments(store: store)` during DEBUG launch, and forward background URLSession completion for `com.gazhenko.sower.speech.model-download`. Core works with Apple fallback until that runtime factory is installed. The comparison JSON uses 20 ms resident-process samples, including app baseline; it is not a hardware high-water measurement. Batch word timings arrive after FluidAudio's seam merge; per-chunk UI progress uses the added `onProgress` protocol overload, then real finalized sentences use `onSegments`.

Physical-iPhone ASR quality/performance, memory/thermal/background behavior, live Wi-Fi/cellular/resumable model transfer, and the fully wired DEBUG comparison launch on device were **not performed**. Fake transport state tests, Mac model inference, simulator checks, and unsigned builds are distinct evidence. Original recordings are retained/protected; only app-owned model/debug fixtures are touched.

```sh
git diff --check -- Packages docs/prototype/CORE-NOTES.md docs/REVIEW.md
```

**PASS, exit 0.** All 39 shared cached model files were also rehashed after inference and still matched the reviewed manifest sizes/SHA-256 values. Build output, generated validation project, logs, model symlinks, and new synthetic fixtures are in ignored build/.build directories.


## Section 15 — Simulator model memory gates (2026-10-10)

Fixed `SpeechMemory.available()` and the Qwen load/generation memory checks via `LocalModelMemory`: iOS Simulator uses `host_statistics64` free + inactive pages multiplied by `host_page_size`, instead of the unavailable jetsam budget. Host-query failure still returns zero; all model headroom thresholds remain unchanged. Physical iOS retains the process-budget value, including zero. [Apple's API documentation](https://developer.apple.com/documentation/os/os_proc_available_memory) and the installed iPhoneOS26.5 SDK `usr/include/os/proc.h` document zero for a non-app process or an exceeded limit, with no documented unlimited-budget exception. The existing Mac estimates are preserved (host headroom for Speech, physical memory for Qwen).

Added parameterized tests in both packages for source selection with zero, low, and ample process budgets, verifying that Simulator/Mac never query the process-budget provider and that device budgets never fall back to abundant host memory. Zero/low memory remain finite values. The Parakeet adapter fallback test now also covers zero explicitly.

### Offline package tests

The existing Speech build state uses the supplied offline FluidAudio checkout. Its exact release pin was temporarily replaced with that local path for validation, then restored byte-for-byte. No dependencies or models were installed/downloaded; LocalModel used its existing resolved checkout/cache. Initial manifests were saved under ignored `build/memory-gate-fix/` before editing. Exact override, test, and restoration commands:

```sh
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
original = Path('build/memory-gate-fix/SermonSetSpeech.Package.swift.original').read_text()
assert p.read_text() == original, 'Speech manifest changed during the task'
p.write_text(original.replace('.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: [])', '.package(path: "../../build/asr-lab/FluidAudio", traits: [])'))
PYCODE
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/memory-gate-fix/speech-tests.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/memory-gate-fix/local-model-tests.log 2>&1
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
p.write_bytes(Path('build/memory-gate-fix/SermonSetSpeech.Package.swift.original').read_bytes())
print('Restored original Speech manifest')
PYCODE
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/memory-gate-fix/local-model-tests-final.log 2>&1
```

**PASS, all exit 0.** Speech: 16 reported tests in 7 suites, 0.203 seconds; 15 executed and the opt-in real-model test skipped because its environment paths were absent. LocalModel: 15 tests in 4 suites, 0.752 seconds, both initial and final runs. The final LocalModel run follows the preservation of its original Mac memory estimate. Both new memory suites pass, with five parameter cases per package. These are macOS package tests with fake model/transport fixtures; Speech dependency evidence uses the supplied offline checkout, rather than a fresh remote release resolution.

### Simulator reproduction and helper validation

An ignored executable used the original Speech helper and the exact original Qwen `availableMemory()` body (wrapped without MLX imports). On the already-booted task simulator, the original probe returned `Speech available bytes: 0; Qwen available bytes: 0` and **failed, exit 1**, reproducing the rejected headroom. The original `main.swift` was saved as `main.original.swift` before replacing it for the final probe. Exact initial commands:

```sh
xcrun swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk -target arm64-apple-ios26.0-simulator -module-cache-path build/memory-gate-fix/ModuleCache Packages/SermonSetSpeech/Sources/SermonSetSpeech/SpeechMemory.swift build/memory-gate-fix/LocalModelMemory.original.swift build/memory-gate-fix/main.swift -o build/memory-gate-fix/memory-probe-red > build/memory-gate-fix/probe-red-build.log 2>&1
xcrun simctl spawn 32502FB1-1CBE-4555-B1FE-CF1712B1A45C /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/memory-gate-fix/memory-probe-red > build/memory-gate-fix/probe-red.log 2>&1
```

The final probe compiles the actual updated helpers, queries their default collectors, and injects zero/low/ample process budgets plus zero/low host memory. Exact final commands:

```sh
xcrun swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk -target arm64-apple-ios26.0-simulator -module-cache-path build/memory-gate-fix/ModuleCache Packages/SermonSetSpeech/Sources/SermonSetSpeech/SpeechMemory.swift Packages/SermonSetLocalModel/Sources/SermonSetLocalModel/LocalModelMemory.swift build/memory-gate-fix/main.swift -o build/memory-gate-fix/memory-probe-green > build/memory-gate-fix/probe-green-build.log 2>&1
xcrun simctl spawn 32502FB1-1CBE-4555-B1FE-CF1712B1A45C /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/memory-gate-fix/memory-probe-green > build/memory-gate-fix/probe-green.log 2>&1
xcrun swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk -target arm64-apple-ios26.0 -module-cache-path build/memory-gate-fix/ModuleCache-device Packages/SermonSetSpeech/Sources/SermonSetSpeech/SpeechMemory.swift Packages/SermonSetLocalModel/Sources/SermonSetLocalModel/LocalModelMemory.swift > build/memory-gate-fix/device-typecheck.log 2>&1
```

**PASS, all exit 0.** Final simulator readings were 4,113,514,496 available bytes for each helper; all injected source-selection/low-host-memory checks passed. Actual load thresholds remain authoritative even in Simulator. Device SDK helper type-check passed. This validates the memory helpers on Simulator, not full model inference or physical-iPhone behavior. No simulator was created, reset, shut down, or reconfigured.

An initial green probe compile failed because mixed integer types inferred `[Any]`; the fixture arrays were explicitly typed and the final compile/run above passed. The attempted spawn of that missing executable failed with exit 111. Only ignored probe fixtures were affected.

Scope verification compared file hashes against the task baseline and confirmed unchanged package manifests and no changes outside the two packages and this review note. No `SermonSet/`, root `project.yml`, `web/`, `site/`, or `server/` edits; no commits. Logs, executables, module caches, and original-source fixtures are in ignored workspace directories. Physical-iPhone validation was not performed.

```sh
git diff --check -- Packages/SermonSetSpeech Packages/SermonSetLocalModel docs/REVIEW.md
```

**PASS, exit 0.**


## Section 15 — Parakeet integration follow-ups (2026-10-10)

Implemented only the requested package behavior and this documentation: shared FIFO Parakeet execution with observable waiting state, per-response Foundation Models decoding recovery and independent artifact saving, and speaker-aware Apple/Qwen prompts with primary-speaker-only key phrases. Tests include cancellation, runtime failure releasing the queue, deferred versus real memory pressure, both `GenerationError.decodingFailure` and `DecodingError`, transient/persistent failures at all five Foundation Models response stages, partial fallback, and both Qwen prompt paths. Prompt versions invalidate pre-change notes/insights checkpoints. Existing original-audio protection and listener-edit preservation remain in place.

### Offline dependency setup and restoration

Speech's existing build state refers to the supplied checkout at `build/asr-lab/FluidAudio` (HEAD `fc8c3e4f5103bf63a242453566525272e143a054`), rather than a cached remote 0.17.7 release checkout. For all package/Xcode checks below, its manifest pin was temporarily replaced with that existing local path. LocalModel used its existing resolved dependency checkouts. No dependencies or models were installed/downloaded. The original manifest was saved before the override, and restored byte-for-byte after validation. Exact relevant setup commands:

```sh
mkdir -p build/section15
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
Path('build/section15/SermonSetSpeech.Package.swift.original').write_bytes(p.read_bytes())
PYCODE
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
original = Path('build/section15/SermonSetSpeech.Package.swift.original').read_text()
assert p.read_text() == original
p.write_text(original.replace('.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: [])', '.package(path: "../../build/asr-lab/FluidAudio", traits: [])'))
PYCODE
```

### Passing checks

```sh
scripts/dev.sh test > build/section15/dev-test-final.log 2>&1
```

**PASS, exit 0, TEST SUCCEEDED.** 116 reported tests in 20 suites, 30.970 seconds; the opt-in isolated server test was skipped (115 executed tests). The script generated only the ignored Xcode project and used the already-booted task simulator without creating/resetting/reconfiguring it. Exact wrapped command:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261010-133348-92110.xcresult test
```

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section15/speech-tests-delivery.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section15/local-model-tests.log 2>&1
```

**PASS, both exit 0.** Speech: 18 reported tests in 8 suites, 0.136 seconds; its opt-in cached-model inference test was skipped because model/audio environment paths were absent (17 executed tests). LocalModel: all 16 tests in 4 suites, 0.948 seconds. These are macOS package tests using deterministic runtime/transport fixtures, not live Foundation Models/Qwen/Parakeet inference.

Additional Core checks:

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'FoundationModelRecoveryTests|SpeakerNotesTests|TranscriptionEngineTests|NotesRepairTests' > build/section15/core-regressions-final.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --no-parallel > build/section15/core-serial.log 2>&1
```

**PASS, both exit 0.** Focused regressions: 27 tests in 4 suites, 3.801 seconds. Full serial macOS Core suite: 116 reported tests in 20 suites, 30.542 seconds; the isolated server test was skipped. Parameterized regression cases exercise both decoding error types.

The final requested device command:

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/section15/device-build-delivery.log 2>&1
```

**PASS, exit 0, BUILD SUCCEEDED.** The current app project already includes SermonSetSpeech; the device SDK build compiles and links Core, LocalModel, Speech, and the offline FluidAudio checkout. No app-source or root project.yml edits were needed. The earlier `device-build.log` and `device-build-final.log` iterations of the same command also passed; delivery follows the final FIFO notification/cancellation refinements. This is unsigned device build evidence, not an iPhone launch or physical-device validation.

### Early failures and corrections

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section15/speech-tests.log 2>&1
```

**FAIL, exit 1:** the new queue's throwing continuation needed an explicit `Void` type. Added that annotation. Subsequent complete Speech runs (`speech-tests-final.log`, `speech-tests-verified.log`, `speech-tests-delivery.log`) passed.

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution > build/section15/core-initial.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution > build/section15/core-final.log 2>&1
scripts/dev.sh test > build/section15/dev-test.log 2>&1
```

**FAIL:** macOS Core runs exited 1, and the first simulator run exited 65. The existing guardrail/partial-notes regression expected one reduce call; decoding recovery now requires two. Updated that expectation, then the focused and final full suites passed. Default concurrent macOS runs also exposed the `automaticPipelineDownloadsWithIndeterminateProgressThenProducesSummary` capability assertion (`needsDownload` versus `available`), and the second exposed the timed `crashSnapshotRecoversOnlyCompletedSegmentsAndIsIdempotent` fixture finding no completed segments. The final explicitly serial full macOS suite and required simulator suite both passed; no unrelated capability/capture production code was changed to suppress these findings.

The earlier focused command also passed, before the final queue/UI/transient regressions were added:

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'FoundationModelRecoveryTests|SpeakerNotesTests' > build/section15/core-regressions.log 2>&1
```

**PASS, exit 0:** 8 tests in 2 suites, 0.953 seconds.

### Delivered manifest and scope

After all dependent checks finished:

```sh
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
p.write_bytes(Path('build/section15/SermonSetSpeech.Package.swift.original').read_bytes())
assert p.read_bytes() == Path('build/section15/SermonSetSpeech.Package.swift.original').read_bytes()
print('Restored the original Speech manifest byte-for-byte.')
PYCODE
swift package --package-path Packages/SermonSetSpeech dump-package > build/section15/delivered-manifest.json
```

**PASS, exit 0:** the delivered requirement remains exact remote FluidAudio `0.17.7` with an empty traits list. **BLOCKED:** fresh remote-release resolution/build, because the working agreement prohibits requiring network access or installing dependencies. The passing package/app evidence above uses the supplied offline checkout; it does not establish a clean remote 0.17.7 build.

A hash comparison against the task-start snapshot confirms no changes to `SermonSet/`, root `project.yml`, `web/`, `site/`, `server/`, AGENTS.md, or scripts/dev.sh, and restored package manifests. Added/changed source and regression files are under Packages; documentation is limited to CORE-NOTES and REVIEW. No commits, credential access, release signing, or shared-simulator changes. Logs, snapshots, generated output, DerivedData and fixtures are in ignored build/.build directories. Live model inference and physical-iPhone behavior were not validated in this slice.

```sh
git diff --check -- Packages docs/prototype/CORE-NOTES.md docs/REVIEW.md
```

**PASS, exit 0.**


## Section 16 — Parakeet diagnostics, compute fallback, and parallel model transfers (2026-10-10)

Implemented CORE-REQUESTS §16 in Packages only, with these notes and CORE-NOTES. The runtime preserves real NSError details in local traces/Logger and fallback debug detail, tries ANE/GPU/CPU per component including first prediction, caches successful placements per revision, and retains Parakeet words when only diarization fails. Both model managers use four parallel foreground transfers, migrate outstanding work to/from background sessions automatically, journal multiple transfers, aggregate progress by bytes, and retain integrity/cellular/disk protections. No app UI or project configuration changes were needed.

### Offline dependency and fixture setup

Used the explicitly supplied API source `build/asr-lab/FluidAudio`, HEAD `fc8c3e4f5103bf63a242453566525272e143a054`. Its real `encoderComputeUnits` API and public `AsrModels` initializer informed component placement. The existing package build state references that offline checkout. Temporarily replaced Speech's dependency pin for validation, then restored its manifest byte-for-byte; the delivered dependency remains exact remote **0.17.7**, **traits: []**. LocalModel used its existing resolved dependencies/artifacts. No dependencies or model weights were installed or downloaded, and no credentials were accessed. Task-start file hashes and fixtures/logs live under ignored `build/section16/`.

```sh
mkdir -p build/section16
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
Path('build/section16/SermonSetSpeech.Package.swift.original').write_bytes(p.read_bytes())
s = p.read_text()
p.write_text(s.replace('.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: [])', '.package(path: "../../build/asr-lab/FluidAudio", traits: [])'))
PYCODE
```

### Required final checks

```sh
scripts/dev.sh test > build/section16/dev-test-final.log 2>&1
```

**PASS, exit 0, TEST SUCCEEDED.** 118 reported tests in 21 suites, 33.120 seconds; the opt-in isolated-server test was skipped (117 executed tests). Includes the new fallback-debug-detail and transport-migration regressions. The script generated the ignored Xcode project and used the already-booted Codex task simulator; no simulator creation/reset/reconfiguration. Exact wrapped command:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261010-155857-15834.xcresult test
```

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-delivery.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/local-delivery.log 2>&1
```

**PASS, both exit 0.** Speech: 25 reported tests in 10 suites, 0.505 seconds; cached inference was skipped without environment paths (24 executed tests). LocalModel: all 18 tests in 5 suites, 1.069 seconds. Fake loaders verify ANE load failure recovering on GPU, first prediction recovering through GPU/CPU, cancellation, failure details, revision/component preferences, and untested group choices staying out of the cache. Speaker-only failure retains words with nil labels. Transport fixtures verify four active downloads, byte-weighted progress, multi-file pause/resume, out-of-order installation, no background refill, and multiple retained-file restoration. Existing engine/store/checkpoint tests continue to pass.

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/section16/device-build-final.log 2>&1
```

**PASS, exit 0, BUILD SUCCEEDED.** Compiles and links the final Core, Speech, LocalModel, and cached FluidAudio/MLX dependencies with the iOS 26.5 SDK. This is an unsigned device SDK build, not an iPhone launch or A19 Pro execution-plan validation.

### Real cached models and additional check

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter ModelDownloadTransportTests > build/section16/transport-tests.log 2>&1
```

**PASS, exit 0:** one macOS test, 0.100 seconds. It exercises real URLSession suspended-task cancellation/replacement across foreground/background modes, stable tokens, request cellular/expensive-network restrictions, pause of every task, and stale-cancellation suppression without sending requests. The final simulator run uses ordinary suspended test sessions for both modes because the unhosted test runner cannot use nsurlsessiond; production still uses `URLSessionConfiguration.background`. This is deterministic migration/state evidence, not OS background-transfer evidence.

The first cached inference run used the existing ignored validation directory:

```sh
SERMONSET_SPEECH_MODEL_DIR="$PWD/build/speech-validation/models" SERMONSET_SPEECH_AUDIO="$PWD/build/asr-lab/data/ami-sdm-long/ami-sdm-long.wav" swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc --filter CachedModelTests > build/section16/cached-model-tests.log 2>&1
```

**PASS, exit 0:** one real-model test, 16.947 seconds. For final-code verification, created task-local directory symlinks to those existing public weights (model files were not changed):

```sh
python3 - <<'PYCODE'
from pathlib import Path
root = Path('build/section16/models')
root.mkdir(exist_ok=True)
source = Path('build/speech-validation/models')
for name in ['parakeet-ultra', 'speaker-diarization']:
    (root / name).symlink_to((source / name).resolve(), target_is_directory=True)
(root / 'verified-ultra-diarization-v1').write_text('Existing public model cache; offline validation only\n')
PYCODE
SERMONSET_SPEECH_MODEL_DIR="$PWD/build/section16/models" SERMONSET_SPEECH_AUDIO="$PWD/build/asr-lab/data/ami-sdm-long/ami-sdm-long.wav" swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc --filter CachedModelTests > build/section16/cached-model-delivery.log 2>&1
```

**PASS, exit 0:** one real Ultra/offline-diarizer test, **11.835 seconds**, producing **79 finalized segments, five speakers, and 160 progress callbacks** from the supplied 4.6-minute public AMI audio. This validates local component loads, tensor prediction probes, public FluidAudio model construction, ASR, and diarization on this Mac. Timings include warm Core ML caches; they are not an iPhone performance comparison or a download-speed measurement.

### Regression failure and intermediate outcomes

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc --filter SpeechParallelDownloadTests > build/section16/download-red.log 2>&1
```

**Expected FAIL, exit 1:** before the fix, the new regression found one active transfer instead of four, incorrect aggregate byte progress, and only two starts instead of eight across pause/resume. The final suite passes the same regression.

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-initial.log 2>&1
```

**FAIL, exit 1:** the incremental package plan did not discover the newly added Core transport source, and one disk-space expression exceeded Swift's type-checking limit. Refreshed the Core manifest mtime (content unchanged) and split the expression:

```sh
touch Packages/SermonSetCore/Package.swift
```

Subsequent complete package commands/outcomes, before final cleanup and delivery:

```sh
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-second.log 2>&1
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-third.log 2>&1
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-fourth.log 2>&1
swift test --package-path Packages/SermonSetSpeech --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/speech-final.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/local-initial.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/local-second.log 2>&1
swift test --package-path Packages/SermonSetLocalModel --disable-automatic-resolution --skip-update --disable-keychain --disable-netrc > build/section16/local-final.log 2>&1
```

**PASS, all exit 0.** Speech second/third: 19 reported tests; fourth/final: 24, each skipping cached inference. Local initial: 17 tests; second/final: 18, none skipped. Delivery runs above include the final changes.

```sh
scripts/dev.sh test > build/section16/dev-test.log 2>&1
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/section16/device-build.log 2>&1
```

Initial simulator run: **FAIL, exit 65**, one new transport test failure; all other Core tests passed. Its attempt to create real background-session tasks from the test host reported NSCocoaErrorDomain **4097**, connection to `com.apple.nsurlsessiond` unavailable. The suspended no-network test mode now substitutes a normal session and avoids app lifecycle/background-task calls; production configuration is unchanged. Final simulator run passes. Initial device build: **PASS, exit 0, BUILD SUCCEEDED**; repeated after final source changes, also passing.

### Restoration, scope, and validation limits

After every dependent build/test finished:

```sh
python3 - <<'PYCODE'
from pathlib import Path
p = Path('Packages/SermonSetSpeech/Package.swift')
p.write_bytes(Path('build/section16/SermonSetSpeech.Package.swift.original').read_bytes())
assert p.read_bytes() == Path('build/section16/SermonSetSpeech.Package.swift.original').read_bytes()
print('Restored the original Speech manifest byte-for-byte.')
PYCODE
swift package --package-path Packages/SermonSetSpeech dump-package > build/section16/delivered-manifest.json
git diff --check -- Packages docs/prototype/CORE-NOTES.md docs/REVIEW.md
```

**PASS, exit 0.** A task-start hash comparison confirms unchanged package manifests and no edits/additions in `SermonSet/`, root `project.yml`, `web/`, `site/`, `server/`, AGENTS.md, or scripts/dev.sh. Existing worktree changes are preserved. No commits, release signing, credential access, or shared-simulator changes. Generated projects, DerivedData, temporary fixtures, resume/preference files used by tests, and logs stay in ignored workspace directories.

**BLOCKED / not performed:** physical iPhone 17 Pro/iOS 27/A19 Pro recovery, live foreground throughput and OS background scheduling/resume, and fresh remote FluidAudio 0.17.7 resolution. The physical environment was not exercised, and the working agreement prohibits requiring network access or installing dependencies. Passing local fake-loader/state checks, Mac cached inference, and device compilation do not establish those results.

## Section 17 — Voice Focus preview API (2026-10-10)

Implemented CORE-REQUESTS §17 in `Packages/SermonSetCore`, with the exact `VoiceFocusPreview` value and MainActor `SermonStore.previewVoiceFocus(sermonID:strength:processMusic:around:)` signature. Preview and full copy share their processing chain and the same cached whole-trim gain estimate. Temporary matched PCM pairs are protected, excluded from backup, removed on the next request/store initialization, and never inserted into the library. Cancellation propagates from callers and newer requests without publishing a stale result. CORE-NOTES documents the API, short-recording behavior, estimate/cache details, and URL lifetime.

### Required final validation

```sh
scripts/dev.sh test > build/section17/dev-test-final.log 2>&1
```

**PASS, exit 0, TEST SUCCEEDED.** 126 reported tests in 22 suites, **33.437 seconds**, with the existing opt-in `nativeClientAgainstIsolatedWorker` test skipped (**125 executed**). All eight new preview tests pass. Includes actual public-API automatic selection from bundled AAC audio, invalid-input preservation, music/quiet skipping, trim/playhead bounds, matched A/B loudness, exact full-copy gain agreement and corresponding AAC excerpt level, cache reuse/invalidation, next-preview/startup cleanup, overlapping/caller cancellation, unchanged store bytes/assets/original checksum, and equivalence with scalar DSP/meter/limiter formulas.

Exact wrapped command:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261010-230712-89189.xcresult test
```

The script generated the ignored Xcode project and found the existing Codex task simulator already booted. No simulator creation, reset, reconfiguration, app installation/launch, or shared-simulator changes were performed. Declared app packages resolved through the available Xcode package cache; the first script run created its ignored FluidAudio 0.17.7 working copy. No dependency manifest edits, manual dependency/model installs, or credentials were needed. Core remains dependency-free.

The timing test measured real 48 kHz AAC speech excerpts in the **Debug simulator**: **0.671 s cold**, **0.638 s with cached source/new settings**, **0.453 s with cached gain**, and **0.496 s for automatic selection with cached gain**. It prints timings rather than imposing a machine-dependent deadline. The earlier Debug macOS fixture measured 0.697 / 0.676 / 0.483 seconds respectively. These are fixture measurements, not a physical-iPhone latency guarantee. Loudness uses the documented bounded whole-trim estimate; both preview and full render use its exact gain, but the estimate/limiter/codec do not promise an exact final -16 LUFS for every source.

### Focused and intermediate commands

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter VoiceFocusTests > build/voice-focus-baseline.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter VoiceFocusTests > build/section17/core-initial.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'VoiceFocusTests|VoiceFocusPreviewTests' > build/section17/core-preview-seventh.log 2>&1
scripts/dev.sh test > build/section17/dev-test.log 2>&1
```

**PASS, all exit 0.** Baseline: 4 tests, 12.732 seconds. Initial shared renderer: 4 tests, 5.984 seconds. Focused final implementation: 12 tests in 2 suites, 9.447 seconds. First simulator run: 126 reported tests in 22 suites, 33.444 seconds, same single opt-in skip. The required final run above adds assertions for real AAC automatic selection and invalid inputs preserving store state.

These intermediate commands failed and were resolved before the passing checks:

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'VoiceFocusTests|VoiceFocusPreviewTests' > build/section17/core-preview-tests.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter VoiceFocusPreviewTests > build/section17/core-preview-second.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter VoiceFocusPreviewTests > build/section17/core-preview-third.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'VoiceFocusTests|VoiceFocusPreviewTests' > build/section17/core-preview-fourth.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'VoiceFocusTests|VoiceFocusPreviewTests' > build/section17/core-preview-fifth.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter VoiceFocusPreviewTests > build/section17/core-preview-sixth.log 2>&1
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'realSamplePreviewLatency|matchedPairUsesWholeTrimGainAndLeavesStoreUntouched' > build/section17/core-timing.log 2>&1
```

All exited **1**. First/second: Swift could not type-check a compound test waveform expression; fourth: the same compiler limit in a spectral-power expression. Both expressions were split. Third: selection included the final 0.4 seconds of an already-detected music run; selection now carries sustained detections across rolling-window boundaries. That run also tried to encode a 16 kHz fixture using the existing 96 kbps AAC full renderer, yielding Core Audio error 560226676; the full-copy fixture now uses supported 48 kHz. Fifth/sixth/timing: the full-copy comparison used broadband synthetic noise, for which AAC changed the weighted level by 1.41 dB (0.60 dB after smoothing); the fixture now uses reproducible speech-band frequencies. The comparison's **0.25 LUFS tolerance was retained**, as was the separate exact gain equality assertion. Initial AAC preview latency was 1.66 s cold / 1.26 s for new settings; buffered native Accelerate calculations and the bounded estimate reduced it to the final timings above. Temporary timing instrumentation was removed from production sources.

### Scope and remaining validation

```sh
git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md
```

**PASS, exit 0.** Task edits are limited to Core source/tests and the two requested documentation files. Existing/concurrent changes under `SermonSet/` and CORE-REQUESTS are preserved. This task made no edits to `SermonSet/`, `project.yml`, `web/`, `site/`, `server/`, scripts, or other package manifests. New fixtures, logs, generated projects and DerivedData are in ignored workspace directories. No commits, push, deployment, release signing, credential access, or coordinator changes.

**BLOCKED / not performed:** physical iPhone preview listening, latency, interruptions and codec/acoustic validation; no physical iPhone was exercised. The passing simulator suite is not physical-device or app-launch evidence.

## Section 18 — Automatic Voice Focus and preferred listening audio (2026-10-10)

Implemented CORE-REQUESTS §18 in `Packages/SermonSetCore`. Automatic processing creates a full-length Voice Focus copy at strength 0.5 with `processMusic: false`, alongside transcription/notes, with independent job state and automatic provenance. The copy becomes the persisted listening choice; unavailable or removed choices fall back to canonical audio. Player choices persist, moments keep their original timeline, and manual rendering takes precedence and deletes superseded automatic files. Originals, transcription inputs, and sharing's explicit trim/selection rules are preserved. Cancelled copies resume from their original; terminal automatic failures remain readable and non-fatal. An initial capability-probe race exposed by the extra concurrent work is guarded so it cannot overwrite newer speech-asset readiness.

Exact new public API names for Claude:

```swift
// SermonStore, @MainActor
public var voiceFocusAfterRecording: Bool { get set }
public func processVoiceFocusAfterRecording(sermonID: UUID) async
public func preferredListeningAssetID(for sermonID: UUID) -> UUID?
public func preferredListeningAsset(for sermonID: UUID) -> AudioAsset?
public func setPreferredListeningAsset(_ assetID: UUID?, for sermonID: UUID) throws
// ProcessingJobs
public var voiceFocus: JobState
public init(transcription: JobState = .idle, insights: JobState = .idle,
            summary: JobState = .idle, voiceFocus: JobState = .idle)
// AudioDerivativeProvenance
public var madeAutomatically: Bool?
```

`processRecording(sermonID:)`, `renderVoiceFocus(sermonID:strength:processMusic:)`, and the public player signatures remain callable as before. CORE-NOTES §18 documents the saved-ID/resolved-asset distinction, old-provenance decoding, task ownership, moment behavior, background recovery, and the exact recorder integration for Claude. The current UI gates `processRecording` on automatic notes; Claude must add the independent `processVoiceFocusAfterRecording` call when notes are off. This task intentionally makes no app-source or settings-UI edits.

### Required final validation

```sh
scripts/dev.sh test > build/section18/dev-test.log 2>&1
```

**PASS, exit 0, TEST SUCCEEDED.** **136 reported tests in 23 suites**, **91.497 seconds**; the existing opt-in `nativeClientAgainstIsolatedWorker` test is skipped (**135 executed**). All **10 new AutomaticVoiceFocusTests** pass. Coverage includes defaults/persistence/legacy decoding; recommended full-recording rendering despite a saved trim; checksums, provenance and anchors; notes finishing while the renderer is held; awaiter cancellation and deduplication; disable/non-fatal failure behavior; player source persistence and missing/removed-copy fallback; moments on full and trimmed sources; deletion of superseded automatic files; manual/automatic races; original-only manual/automatic ASR and retranscription with Parakeet/Apple/fallback; relaunch recovery; and deletion during rendering. Existing Voice Focus preview, speech-asset, summary/notes and playback regressions also pass.

Exact script-wrapped command:

```sh
xcodebuild -project SermonSet.xcodeproj -scheme SermonSetCore -configuration Debug -destination 'platform=iOS Simulator,id=32502FB1-1CBE-4555-B1FE-CF1712B1A45C' -derivedDataPath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/DerivedData-core -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath /Users/jemmygazhenko/Documents/GitHub/sermonset-ios/build/logs-core/tests-20261010-235058-98960.xcresult test
```

The script generated the ignored project and found the existing Codex task simulator already booted. No simulator was created, reset, reconfigured, or manually launched. This is simulator test evidence, not physical iPhone validation.

```sh
xcodebuild build -project SermonSet.xcodeproj -scheme SermonSet -destination 'generic/platform=iOS' -derivedDataPath build/codex-device -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO > build/section18/device-build.log 2>&1
```

**PASS, exit 0, BUILD SUCCEEDED.** Unsigned arm64 iOS app compilation includes the package API changes and the existing UI worktree. Xcode used the available dependency cache, including a cached FluidAudio 0.17.7 checkout under the ignored device DerivedData. No package dependencies were added, manifests changed, credentials accessed, or release signing performed. This command does not install or run the app on an iPhone.

### Focused and intermediate checks

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'VoiceFocusTests|SummaryTests|RecordingSpeechAssetsTests' > build/section18/core-initial.log 2>&1
```

**FAIL, exit 1:** 21 tests in three suites; two existing speech-asset assertions found `.needsDownload` after the pipeline had already downloaded/rechecked the assets. An initial asynchronous capability probe could publish a stale result after the newer processing result. Capability revisions now reject those late writes; transcription source selection and ASR behavior are unchanged.

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'AutomaticVoiceFocusTests|VoiceFocusTests|SummaryTests|RecordingSpeechAssetsTests' > build/section18/core-focused.log 2>&1
```

**FAIL, exit 1:** the new test fixture's compound timestamp expression exceeded Swift's type-checking limit, and nested `#require` macros failed recursive expansion. Split the expression and unwrap provenance before encoding; no production behavior was changed for these compiler errors.

```sh
swift test --package-path Packages/SermonSetCore --disable-automatic-resolution --filter 'AutomaticVoiceFocusTests|VoiceFocusTests|SummaryTests|RecordingSpeechAssetsTests' > build/section18/core-focused-second.log 2>&1
```

**PASS, exit 0:** 31 tests in four suites, **10.973 seconds**, including all ten new tests and the previously failing speech-asset assertions. The subsequent required simulator suite additionally checks the final assertion that a moment outside a manual/sharing trim reaches its original timestamp.

### Scope and remaining validation

```sh
git diff --check -- Packages/SermonSetCore docs/prototype/CORE-NOTES.md docs/REVIEW.md
python3 - <<'PY'
from pathlib import Path
import hashlib, json
expected = json.loads(Path('build/section18/protected-hashes.json').read_text())
changed = [p for p, h in expected.items()
           if not Path(p).exists() or hashlib.sha256(Path(p).read_bytes()).hexdigest() != h]
assert not changed, changed
print('Protected files match the task-start snapshot.')
PY
```

**PASS, exit 0.** Task edits are limited to Core source/tests and the two requested documentation files. Task-start file hashes confirm preserved contents in `SermonSet/`, `project.yml`, `web/`, `site/`, `server/`, AGENTS.md and scripts/dev.sh. Existing package preview work and concurrent UI/document changes remain intact. New test fixtures, snapshots, logs, generated projects, and DerivedData are inside ignored workspace directories. No commits, push, deployment, release signing, credential access, or coordinator changes.

**BLOCKED / not performed:** physical iPhone listening/latency, real microphone capture with the automatic pipeline, and OS background scheduling/expiration. This environment exercised local audio fixtures, simulator playback/tests and unsigned device compilation. The standalone Voice Focus-only call journals interrupted work for foreground/relaunch recovery; it does not submit the summary's continued-processing lease or require new app background configuration.
