# HANDOFF TO NEXT AGENT — TOTOROX

Last updated: 2026-11-13 (takeover inspection). Rewritten because the previous
version described an older project state and contradicted the actual source code.

Status legend: COMPLETED (implemented + verified) / IN PROGRESS / PENDING /
BLOCKED / UNVERIFIED (implemented, not validated).

---

## 1. Project overview

- **Name:** `Totorox` (never `Tororox`).
- **Type:** iOS application, Swift 5 language mode, SwiftUI, deployment target iOS 16.0.
- **Bundle ID:** `com.apple.mobile.MobileHouseArrest`, marketing version `1.1`.
- **Build system:** XcodeGen — `project.yml` is the only source of truth.
  `Totorox.xcodeproj` is gitignored and must be generated with `xcodegen generate`.
- **App target:** `Totorox` (34 Swift files + bridging header `Totorox/Totorox-Bridging-Header.h`).
- **Test target:** `TotoroxTests` (XCTest, `@testable import Totorox`, `ENABLE_TESTABILITY: YES`).
- **CI:** `.github/workflows/build-and-test.yml` runs on `macos-latest`:
  `xcodegen generate` → `xcodebuild test` → unsigned archive → IPA artifact.
- **Purpose:** app-container file manager plus `.3105` ↔ `.zip` patch conversion,
  multi-mod smart merge, guided overwrite flow.
- **Language resources:** `en.lproj`, `vi.lproj`, `zh-Hans.lproj` (198 keys each, in parity).
- **Backend:** `TotoroxBackend/` (FastAPI blueprint: license key + HWID, `/api/v1/convert`,
  `/api/v1/merge`) described in `sever_security.md`. It is a design blueprint and is
  **not wired to the iOS client**. Do not delete it.

## 2. Original user requirements (reconstructed)

Standing requirements, still in force:

1. App-container browsing and file operations (copy / cut / paste / rename / delete / create folder),
   including access to `/var/mobile/Containers/Data/Application`.
2. Windows-style recursive merge: file overwrite without hash checks; folder→folder merges
   recursively and never deletes the destination; type conflicts (file↔folder) must ask the user
   (`Replace` / `Skip` / `Replace All` / `Cancel`) and must never silently delete destination data.
3. Bidirectional `.3105` ↔ `.zip` conversion preserving structure, metadata and payloads.
4. Hard **3.6 GB** ceiling for any archive or patch package, compressed and expanded,
   enforced *before* allocating memory.
5. Accurate result reporting: `Succeeded` / `Failed` / `Skipped`, cancellable operations,
   and a cut must never delete its source unless everything was copied.
6. All disk I/O off the main thread (`Task.detached` / background queues); UI updates only on `DispatchQueue.main`.
7. Bundle IDs resolved from `[Container_Path]/.com.apple.mobile_container_manager.metadata.plist`
   key `MCMMetadataIdentifier` — never show raw UUIDs as app identity.
8. Full localization in en / vi / zh-Hans, defaulting to system language.
9. Do not fabricate engine logic from reverse-engineered guesses; reuse the original
   3105 / FilzaSlop mechanics that already exist in the codebase.
10. The user speaks Vietnamese — reply in Vietnamese, even when the prompt is English.

## 3. Current project status

The repository is mid-way through an **uncommitted security / resource-hardening pass**
started by the previous agent after commit `bc44429`. The code is written and appears
complete and internally consistent, but **nothing is committed and nothing has been compiled
or tested on this machine**. Treat the whole change set as UNVERIFIED.

## 4. Completed tasks

COMPLETED (verified by reading the committed source):

- Full rename to `Totorox` (no `Tororox` remains in code/config).
- Bundle-ID resolution via MCM metadata plist (`ContainerStore.swift` lines ~861/914/1236,
  plus `AppIconHelper.m`).
- File I/O engine with merge rules, conflict prompting, cancellation and reporting.
- `.3105` ↔ `.zip` converter (`PatchZipConverter`), patch package codec, ZIP reader/writer/extractor.
- Localization infrastructure with en/vi/zh-Hans parity.
- Info.plist document types, entitlements, bridging header, XcodeGen config, CI workflow.
- 39 test methods across 4 test files (21 FileIO, 11 PatchZip, 4 size-limit, 3 path-validator).

## 5. In-progress tasks (UNVERIFIED, uncommitted)

The hardening pass in the working tree:

- 3.6 GB limit (`PatchPackageLimits.maximumExpandedBytes`) enforced in `PatchZipConverter`,
  `AovModMergerEngine`, `PatchPackageCodec`, `ZIPArchiveExtractor`, `ZIPArchiveWriter`,
  `PatchConverterView`, `OverwriteFileView`, `FolderExplorerView`.
- ZIP64 / bounds / integer-overflow hardening (`Int.max` guards, `addingReportingOverflow`,
  `count - offset` comparisons) in both ZIP parsers.
- Symlink rejection for copy / rename / create-folder (`FileIOEngineError.symbolicLinkUnsupported`).
- Data-loss guards: copy-onto-self is a no-op (reported as skipped, not succeeded),
  folder-into-own-subfolder rejected, `canDeleteCutSource` gate for cut/paste,
  `renameItem` refuses to overwrite, in-place overwrite keeps a rollback backup.
- UI path validation (`PatchPathValidator`, `validatedName` now rejects `\`) and container-escape
  checks in the overwrite flow; user-visible error alerts instead of silent `try?`.
- `ContainerStore.readTextFile` no longer loads whole files; `AppLog` bounded to 5,000 entries.
- README / Info.plist / localization / `.gitignore` updates.
- Follow-up pass (requested by the user after the audit review):
  - Symlink rejection now walks **every component from the app-container root down**, not just the
    item and its immediate parent. Components above `.../Containers/Data/Application/<UUID>` are
    skipped on purpose, because `/var` is itself a symlink on stock iOS.
  - Shared incoming files are copied on a background task (`importSharedFile`) instead of the main thread.
  - `totorox://overwrite?url=` / `import?url=` accept **https only**, and reject a download whose
    declared or actual size exceeds the 3.6 GB ceiling.
  - Conversion outputs in `tmp/ConvertedPatches` are pruned to the files referenced by the live
    history (max 10), and history entries whose file is gone are dropped instead of failing silently.
  - Converted-size labels read `NSNumber` instead of `Int64` (they always showed 0 bytes).
- Phase 1 thin-client scaffolding (additive — nothing is wired into the UI, the app behaves exactly
  as before):
  - `helpers/KeychainHelper.swift` — HWID + license key storage, `…ThisDeviceOnly` accessibility.
  - `helpers/LicenseManager.swift` — `@MainActor` activation state; HWID generated once in the Keychain.
  - `helpers/APIService.swift` — sends `X-License-Key` / `X-HWID`, streams multipart bodies to a temp
    file, calls `api/v1/activate`, `api/v1/convert`, `api/v1/merge`. **`defaultBaseURL` is a placeholder
    (`https://api.totorox.app`) and must be changed before use.** Uploads are capped at 64 MB in phase 1
    because large mods still have to be processed on-device.
  - `views/ActivationView.swift` — activation screen; it can be presented but is deliberately not
    presented anywhere, so an empty backend cannot lock the app.
  - The conversion/merge engines were intentionally **not** deleted: `TotoroxBackend/*.py` are still
    empty 0-byte files, so routing those features to the server now would remove all functionality.

## 6. Pending tasks

PENDING:

1. Commit the working tree (nothing is committed; uncommitted work is at risk).
2. Obtain a real compile + test verdict (only possible on macOS / via CI).
3. Keep `scripts/test_engine.py` in sync — it still mirrors only the old merge rules and does not
   exercise the Swift sources at all.

RESOLVED by user decision (2026-11-13):

- The 3.6 GB ceiling stays as-is (no streaming rewrite planned).
- Removing `.3105` extraction from the Files tab is intentional; do not restore it.
- The update checker target `VannHoc/Totorox` is the correct repository.

BLOCKED (on this machine):

- No `swift`, `xcodebuild` or `xcodegen` available (Windows host). Cannot build, cannot run XCTest.

## 7. Modified files (uncommitted, 22)

```
.gitignore
README.md
Totorox/Info.plist
Totorox/en.lproj/Localizable.strings
Totorox/vi.lproj/Localizable.strings
Totorox/zh-Hans.lproj/Localizable.strings
Totorox/engine/AovModMergerEngine.swift
Totorox/engine/FileIOEngine.swift
Totorox/engine/PatchZipConverter.swift
Totorox/helpers/ContainerStore.swift
Totorox/helpers/FileManagerService.swift
Totorox/helpers/PatchPackageCodec.swift
Totorox/helpers/PatchProjectModels.swift
Totorox/helpers/Utils.swift
Totorox/helpers/ZIPArchiveExtractor.swift
Totorox/helpers/ZIPArchiveWriter.swift
Totorox/views/FolderExplorerView.swift
Totorox/views/OnboardingView.swift
Totorox/views/OverwriteFileView.swift
Totorox/views/PatchConverterView.swift
Totorox/views/SettingsView.swift
TotoroxTests/FileIOEngineTests.swift
```

Diff size: **+982 / −109**.

## 8. Created files (uncommitted, untracked)

```
TotoroxTests/ArchiveSizeLimitTests.swift    (4 tests)
TotoroxTests/PatchPathValidatorTests.swift  (3 tests)
```

## 9. Deleted code paths (no files deleted)

No files were removed. Two code paths were removed **inside** existing files by the previous
agent — both need user confirmation before they are considered final:

1. `FolderExplorerView`: `.3105` is no longer treated as an extractable archive.
   The UI affordance and the decode-and-stage branch inside `extractArchive` were deleted;
   only `.zip` extracts now. **Confirmed intentional by the user on 2026-11-13 — do not restore.**
2. `AppUpdateChecker` (Utils.swift): release URLs moved from `Totorox/Totorox` to
   `VannHoc/Totorox` (the real remote).

## 10. Technical decisions (from the previous agent, verified)

- One shared constant for the size ceiling (`PatchPackageLimits`) instead of per-call magic numbers.
- All limits applied on the *declared* size before allocation; sums tracked with overflow reporting.
- Symlinked source, destination, or destination parent is rejected rather than followed —
  prevents writes being redirected outside the intended item.
- Copy-onto-self returns `skipped`, never `succeeded`, because cut/paste deletes the source
  when the result "looks successful".
- Overwrite always keeps a rollback backup before in-place POSIX rewriting.
- `renameItem` refuses to replace an existing destination (POSIX `rename(2)` would silently do so).
- `Info.plist` now uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`; the double-nested
  `UILaunchScreen` dict was fixed to a single empty `<dict/>`.

## 11. Build and test results

**iOS:** the last pushed commit (`ad4b449`) passed CI — run `43378617068`, conclusion `success`,
10m16s (macOS runner: `xcodegen` + `xcodebuild test` + unsigned IPA).

**Not yet compiled:** commit `a00ab2d` (KeychainHelper / LicenseManager / APIService /
ActivationView) has **not been pushed**, so no run has built it. Nothing in the app references those
files yet, but they still have to compile.

**Backend:** verified locally on 2026-11-13 with `uvicorn` in a scratch venv (Python 3.15):
`/health` 200; `activate` binds DEVICE-A; same key from DEVICE-B → 403 "Key đang được dùng trên
máy khác"; unknown key → 403; missing headers → 401; `convert` → 501; rate limit allows 5/minute
per key then returns 429. Test database, server log and `__pycache__` were deleted afterwards.

Local tooling: no `swift`, `xcodebuild` or `xcodegen` on the Windows host.
- Static review performed (not a substitute for compiling):
  - All symbols used by the new tests exist with the required access level
    (`PatchPackageLimits`, `PatchPathValidator`, `FileManagerService.validatedName`,
    `public func copySingleFile`, `FileIOResult.init(...)` defaults,
    `shouldReplaceAllConflicts`, `canDeleteCutSource`).
  - Every `switch` over an enum that gained a case was updated (`AovModMergerError`,
    `PatchZipConverterError`, `FileManagerOperationError`, `ZIPArchiveExtractorError` mapping).
    The switch in `PatchZipConverterTests` uses `default:`, so it is unaffected.
  - The size-limit test fixture does reach the new guard (offsets/EOCD checked manually).
  - Localization keys: 198 / 198 / 198 across en / vi / zh-Hans.

**Never claim unverified code builds.** iOS changes after `ad4b449` and the whole backend still
need a real run before they can be called working.

## 12. Known bugs, blockers and risks

- **Uncommitted work.** ~9 hours of changes exist only in the working tree, inside a OneDrive
  folder. Highest risk in the project right now.
- **Swift 6 hazard.** New `Task.detached { … MainActor.run { self.presentOperationError(…) } }`
  captures a non-`Sendable` `View` — legal in Swift 5 mode (matching existing code), an error in
  Swift 6 mode. Do not bump `SWIFT_VERSION` without addressing this.
- **Unverified test.** `FileIOEngineTests` test 6 touches `ContainerMetadataCache.shared` and
  `ContainerStore.listFiles` on a simulated container path; it may be the first CI failure.
- `.gitignore` no longer ignores `TotoroxBackend/` or `sever_security.md` (both already tracked)
  and dropped the `fix_*/file_mod/` patterns — a broad `git add -A` could pick up stray folders.
- The old handoff demanded restoring C / Objective-C cores from the `3105` binary via disassembly.
  That contradicts the current all-Swift implementation and must **not** be executed as written.
  The requirement it encodes (do not invent engine logic; reuse original 3105/FilzaSlop mechanics)
  remains valid.

## 13. Git working-tree status

- Branch: `main`. No stashes. Nothing staged.
- **The repository was re-initialised on 2026-11-13**: there is a single initial commit
  `78e9436 "build app"` containing 95 files / 49,401 insertions. The previous history
  (14 commits ending at `bc44429`) is no longer reachable in this clone — `bc44429` is not a valid
  object. The two new test files are tracked in that commit; no work is missing.
- Only the follow-up fixes from this pass are uncommitted (see §5).

## 14. Exact next steps

1. Commit the uncommitted follow-up fixes from §5.
2. Push only if the user authorizes, then read the macOS CI result — this is the only trustworthy
   compile verdict available.
3. If CI fails, fix the reported compile/test errors; rerun the same check only.
4. Decide with the user whether `scripts/test_engine.py` should be extended or removed.
5. Confirm with the user that re-initialising the repository was intentional (see §13).
6. Deploy `TotoroxBackend/` to a free tier host, then set `APIService.defaultBaseURL` to that URL.
7. Phase 2 (only after the backend works): finish `TotoroxBackend/` (the license + HWID table,
   `/api/v1/activate|convert|merge`, rate limit, temp-file cleanup), then present `ActivationView`
   and gate the UI on `LicenseManager.status.isActive`. Only then remove the duplicated local logic
   in `PatchZipConverter` / `AovModMergerEngine`, and only for the parts that actually moved server-side.

## 15. Constraints for the next agent

- Continue, do not rebuild. Never `git reset --hard`, never `git clean`, never discard uncommitted work.
- Smallest safe change; no unrelated refactors; preserve API contracts, entitlements, signing config.
- Never expose secrets, keys or credentials. `sever_security.md` and `TotoroxBackend/` contain
  design/backend material — do not publish or ship it inside the app.
- Never claim a build or test passed unless it actually ran.
- Reply to the user in **Vietnamese**, concisely. Prompts may arrive in English.
- Keep this file updated after every meaningful milestone, not only at the end.

---

## Appendix — original handoff mandates (preserved, superseded where noted)

Constraints from the previous handoff that are still valid: never fabricate engine logic from
guessed disassembly; resolve Bundle IDs from `MCMMetadataIdentifier`; keep all disk I/O off the
main thread; standardise the project name as `Totorox`; prioritise `AppContainerScanner` and
`FileIOEngine`.

Superseded / already done: the "critical regressions" list (sandbox I/O, UI freeze, UUID shown
instead of bundle ID, simulated overwrite flow) no longer matches the source and must not be
re-implemented from scratch; the `Tororox` → `Totorox` rename is complete; the instruction to
port C / Objective-C cores from the `3105` binary conflicts with the current Swift implementation
— verify with the user before acting on it.
