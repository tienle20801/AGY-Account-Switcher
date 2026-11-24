# AGY Account Switcher

macOS Menu Bar utility (`NSStatusItem` + top-anchored `NSPanel`) for **1-click Antigravity (AGY) account switching**, **flexible dynamic multi-bucket quota tracking** (Gemini core pools, Claude/GPT, plus automatic discovery/pruning of dedicated server pools), **per-bucket Smart Auto-Switch** (`monitoredBucketIDs` + any/all match mode, idle-aware or threshold-triggered with priority/round-robin selection & cancellation), **Weekly Quota Warmup** (opt-in minimal request to start 7-day reset timers early for eligible shared Gemini & Claude/GPT weekly buckets), **`agy` CLI + standalone `agy --hub` + IDE 2.6+ sync**, **Quick Summary Header** (today's token donut, cache hit %, estimated USD API cost & aggregate pool quota), **Card / Compact views**, **JSON export/import & refresh-token seeding**, **configurable low-quota threshold notifications**, and **companion lifecycle sync**.

## Architecture (Clean Root)
- `desktop/`: Swift Package Manager macOS SwiftUI MenuBarExtra application (`AGYAutoChanger`)
  - `Sources/AGYAutoChanger/App/`: `AGYAutoChangerApp.swift` (AppKit `MenuBarPanelController` + `FloatingPopoverPanel`)
  - `Sources/AGYAutoChanger/Models/`: `AppConfig.swift`, `AccountProfile.swift` (incl. `remark`, `isDisabled`, display preferences, granular `AutoSwitchPolicy` (`monitoredBucketIDs` + `triggerMatchMode`), `WeeklyWarmupPolicy` & `PortableAccountExportBundle`), `ModelUsage.swift` (incl. `isUnknownObservation`, dynamic `resolveQuotaBucketDescriptor`, `groupMembersHint`, and unified Gemini 4 shared pool mapping), `SwitchState.swift`
  - `Sources/AGYAutoChanger/Services/`:
    - `Auth/`:
      - `VaultSecurityService.swift`: `0700`/`0600` vault snapshots, `~/.gemini/antigravity-cli/antigravity-oauth-token` sync (`restoreCLITokenOnly`), atomic protected writes (`writeProtectedData`), path validation, atomic swap with `.rollback` recovery
      - `KeychainFallbackService.swift`: Native `SecItemCopyMatching`/`SecItemAdd`/`SecItemDelete` sync for Antigravity 2.0's primary `gemini`/`antigravity` Keychain item (`go-keyring`), `security -i` batch delete/import, OAuth token refresh, refresh-token/JSON credential seeding (`seedProfileCredentials`), unexpired in-memory bearer token extraction, and `userTier` metadata parser
    - `Quota/`:
      - `CloudCodeQuotaService.swift`: Dynamically syncs official Dashboard quota buckets (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, plus any server-reported dedicated pools), prunes retired extra pools on sync, extracts `groupMembersHint`, `resetTime`, and `paidTier`/`currentTier` via `daily-cloudcode-pa` → `sandbox` → `cloudcode-pa`, plus `agy -p /usage --output-format stream-json` CLI integration, advertised model discovery, and minimal `v1internal` SSE warmup request transport
      - `QuotaThresholdNotifier.swift`: Sends deduplicated macOS `UNUserNotificationCenter` banners when active account Google/Gemini or dedicated pool quota hits user-configured threshold (default `<= 30%`, toggleable in Settings)
      - `SmartAutoSwitchService.swift`: Pure, deterministic evaluator for opt-in per-bucket automatic switching (`monitoredBucketIDs`, `anySelected` vs `allSelected`, wait-for-idle vs immediate-at-threshold, priority order vs round-robin, quota freshness & weekly+5h sibling safety checks, per-account cancellation auto-clearing on recovery, crash-safe journal state)
      - `WeeklyWarmupService.swift`: Pure, deterministic eligibility & cycle-key deduplication evaluator for opt-in Quota Warmup (7-day `gemini-weekly` & `3p-weekly` plus optional 5-hour `gemini-5h` & `3p-5h` with active-hours & weekly-sibling `> 5%` safety guard, 30-day `0600` history retention, strict exclusion of dedicated pools)
      - `UsageTrackerService.swift`: Strictly read-only SQLite+WAL protobuf (`gen_metadata` + `steps` keyed by `last_step_index`) scanner adapted from `adahime/agy-hud`, plus `transcript.jsonl` fallback, incremental merge preserving dynamic buckets, daily token breakdown (`DailyUsageOverview`: input/output/cached, cache hit %, estimated API cost USD) and pool aggregate quota (`AggregateQuotaOverview`)
    - `Session/`:
      - `AGYStateInspectorService.swift`: Detects active account email from `app_storage.json` (`agy.onboarding.lastLoginUsername`), `antigravity_state.pbtxt`, `Preferences`, IDE `state.vscdb`, and `userTier` metadata
      - `AGYRuntimeCoordinator.swift`: Detects Antigravity IDE 2.6+ shared-credential installations (`product.json`), discovers/stops/relaunches standalone `agy --hub --app_data_dir antigravity` processes, checks CLI initialization, and performs strictly read-only live task/idle inspection
      - `AntigravityProcessMatcher.swift`: Shared matcher for running Antigravity / Antigravity IDE processes
      - `AGYCompanionLifecycleService.swift`: Binds app lifecycle to Antigravity (manages `com.agy.autochanger.watcher` LaunchAgent and quits app after grace period when AGY exits externally, ignoring managed switches)
      - `AccountSwitcherService.swift`: 1-click orchestrator (flush usage delta & backup outgoing -> terminate AGY/IDE 2.6+/standalone `agy --hub` -> atomic restore incl. CLI token -> relaunch Hub + AGY + IDE -> immediate & post-switch Cloud Code Dashboard sync), CLI-only switch (`switchCLISessionOnly`), Smart Auto-Switch runner, serial Weekly Quota Warmup runner with 2s pacing & follow-up quota refresh, account remark/disable/reorder, and portable JSON export/import
  - `Sources/AGYAutoChanger/Views/`: `MenuBarPopoverView.swift` (Quick Summary Header, Smart Auto-Switch & Weekly Warmup status banners, Tier/Model filters, Drag & Drop reordering, JSON menu), `AccountCardView.swift` (Card & Compact micro-strip modes, dynamic dedicated-pool indicator dot, live group member tooltip hints, CLI-only switch & manual warmup actions, hover/always/hidden reset countdown, Unknown `—` dashed track, inline remark editor), `AddAccountSheetView.swift` (Capture current, Clean login, Import Refresh Token / JSON), `SettingsInlineView.swift` (incl. CLI sync, per-bucket Smart Auto-Switch & Weekly Warmup policy)
  - `Sources/AGYWatcher/main.swift`: Lightweight event-driven LaunchAgent helper (`Contents/Helpers/AGYWatcher`) that opens `AGY Account Switcher.app` when Antigravity launches
  - `Tests/AGYAutoChangerTests/`: Modular domain-aligned unit tests:
    - `TestSupport/TempDirectoryTestCase.swift`: Shared isolated temp directory fixture base class
    - `VaultAndKeychainTests.swift`: Vault snapshot/restore, clean login, path traversal, keyring metadata, and refresh-token/JSON export-import tests
    - `AccountProfileAndStateTests.swift`: Account profile tier/initials, backward-compatible decoding, Argon/unknown indicators, and AGY state inspector tests
    - `UsageTrackerTests.swift`: Rolling-window turn tracking, SQLite protobuf scanner, incremental merge, daily token/cost overview, and aggregate pool quota tests
    - `CloudCodeQuotaTests.swift`: Cloud Code Dashboard quota snapshot, dedicated Gemini 4 Carbon pool isolation, `agy -p /usage` CLI parser, and 30% threshold alert tests
    - `LifecycleBindingTests.swift`: Companion lifecycle binding, managed-restart guard, and legacy settings decoding tests
    - `RuntimeAndAutoSwitchTests.swift`: CLI token `0600` sync guard, IDE 2.6+ shared-credential detection, standalone `agy --hub` parsing, read-only activity/idle inspection, and Smart Auto-Switch evaluation (wait-for-idle, priority, round-robin, staleness, cancellation & failure pause)
    - `WeeklyWarmupTests.swift`: Weekly Quota Warmup eligibility rules, Argon/Carbon strict exclusion, cycle-key deduplication & 30-day retention, advertised model selection, SSE-first/transport-only fallback & no-4xx-retry tests, and legacy settings decoding
  - `.gitignore`: Ignores `.build/`, `build/`, `.DS_Store`, `*.xcuserstate`, and `DerivedData/`
  - `scripts/build_app.sh`: Release build and `.app` bundle packager (`desktop/build/AGY Account Switcher.app`)
- `.agy/`: SDLC memory rules and resolved bugs

## Build, Test & Launch
```bash
cd desktop
swift build
swift test
bash scripts/build_app.sh
open "build/AGY Account Switcher.app"
```
