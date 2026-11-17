# AGY Account Switcher

macOS Menu Bar utility (`MenuBarExtra`) for **1-click Antigravity (AGY) account switching**, **real-time multi-bucket quota tracking** (Gemini, Claude/GPT, Argon), **30% threshold notifications**, and **companion lifecycle sync**.

## Architecture (Clean Root)
- `desktop/`: Swift Package Manager macOS SwiftUI MenuBarExtra application (`AGYAutoChanger`)
  - `Sources/AGYAutoChanger/App/`: `AGYAutoChangerApp.swift` (`MenuBarExtra` `.window`)
  - `Sources/AGYAutoChanger/Models/`: `AppConfig.swift`, `AccountProfile.swift`, `ModelUsage.swift`, `SwitchState.swift`
  - `Sources/AGYAutoChanger/Services/`:
    - `Auth/`:
      - `VaultSecurityService.swift`: `0700`/`0600` vault snapshots, path validation, atomic swap with `.rollback` recovery
      - `KeychainFallbackService.swift`: Native `SecItemCopyMatching`/`SecItemAdd`/`SecItemDelete` sync for Antigravity 2.0's primary `gemini`/`antigravity` Keychain item (`go-keyring`), `security -i` batch delete/import, OAuth token refresh, unexpired in-memory bearer token extraction, and `userTier` metadata parser
    - `Quota/`:
      - `CloudCodeQuotaService.swift`: Syncs live official Dashboard quota buckets (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, `argon-weekly`), `resetTime`, and `paidTier`/`currentTier` via `/v1internal:loadCodeAssist`, `/v1internal:retrieveUserQuotaSummary`, `/v1internal:retrieveUserQuota`, `/v1internal:fetchAvailableModels`, plus `agy -p /usage --output-format stream-json` CLI integration for dedicated `Gemini 4 Argon` quota
      - `QuotaThresholdNotifier.swift`: Sends deduplicated macOS `UNUserNotificationCenter` banners when active account Argon or Gemini quota hits `<= 30%`
      - `UsageTrackerService.swift`: Strictly read-only SQLite+WAL protobuf (`gen_metadata` + `steps` keyed by `last_step_index`) scanner adapted from `adahime/agy-hud`, plus `transcript.jsonl` fallback and incremental merge that never resets quota/turns across switches
    - `Session/`:
      - `AGYStateInspectorService.swift`: Detects active account email from `app_storage.json` (`agy.onboarding.lastLoginUsername`), `antigravity_state.pbtxt`, `Preferences`, IDE `state.vscdb`, and `userTier` metadata
      - `AntigravityProcessMatcher.swift`: Shared matcher for running Antigravity / Antigravity IDE processes
      - `AGYCompanionLifecycleService.swift`: Binds app lifecycle to Antigravity (manages `com.agy.autochanger.watcher` LaunchAgent and quits app after grace period when AGY exits externally, ignoring managed switches)
      - `AccountSwitcherService.swift`: 1-click orchestrator (flush usage delta & backup outgoing -> terminate AGY -> atomic restore -> relaunch AGY -> immediate & post-switch Cloud Code Dashboard sync)
  - `Sources/AGYAutoChanger/Views/`: `MenuBarPopoverView.swift`, `AccountCardView.swift`, `AddAccountSheetView.swift`, `SettingsInlineView.swift`
  - `Sources/AGYWatcher/main.swift`: Lightweight event-driven LaunchAgent helper (`Contents/Helpers/AGYWatcher`) that opens `AGY Account Switcher.app` when Antigravity launches
  - `Tests/AGYAutoChangerTests/`: Modular domain-aligned unit tests:
    - `TestSupport/TempDirectoryTestCase.swift`: Shared isolated temp directory fixture base class
    - `VaultAndKeychainTests.swift`: Vault snapshot/restore, clean login, path traversal, and keyring metadata tests
    - `AccountProfileAndStateTests.swift`: Account profile tier/initials and AGY state inspector tests
    - `UsageTrackerTests.swift`: Rolling-window turn tracking, SQLite protobuf scanner, and incremental merge tests
    - `CloudCodeQuotaTests.swift`: Cloud Code Dashboard quota snapshot, `agy -p /usage` CLI parser, and 30% threshold alert tests
    - `LifecycleBindingTests.swift`: Companion lifecycle binding, managed-restart guard, and legacy settings decoding tests
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
