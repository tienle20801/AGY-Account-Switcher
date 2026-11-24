# AGY Account Switcher

Native macOS Menu Bar (`NSStatusItem` + top-anchored `NSPanel`) utility for **1-click Google Antigravity (AGY) account switching**, **dynamic multi-bucket quota tracking**, **per-bucket Smart Auto-Switch**, **Weekly & 5h Quota Warmup**, **`agy` CLI + `agy --hub` + Antigravity IDE 2.6+ sync**, **Quick Summary overview**, **configurable low-quota macOS alerts**, and **companion lifecycle sync**.

## Features

- **1-Click Atomic Account Switching (`⌘1`–`⌘9`) & Portable Profiles**:
  - Flushes telemetry and snapshots outgoing session files (`0700`/`0600` vault under `~/.agy-switcher/`) and `go-keyring` / Keychain OAuth credentials before safely terminating Antigravity + `language_server`, swapping snapshots atomically with rollback protection, and relaunching Antigravity.
  - Supports **Clean Login** flow to sign into additional accounts without wiping saved profiles or workspace layouts, plus **Portable JSON Export/Import** and **Refresh Token Seeding**.
- **Dynamic Multi-Bucket Quota Tracking**:
  - Tracks shared **Gemini 5h / Weekly** and **Claude & GPT 5h / Weekly** pools alongside dynamic discovery and automatic pruning of dedicated server pools (such as **Gemini 4 Argon** and **Gemini 4 Carbon**), with live group-member tooltips.
  - Combines Cloud Code REST endpoints (`/v1internal:loadCodeAssist`, `/v1internal:retrieveUserQuotaSummary`, `/v1internal:retrieveUserQuota`, `/v1internal:fetchAvailableModels`), official Antigravity CLI (`agy -p /usage --output-format stream-json`), and strictly read-only SQLite + `transcript.jsonl` telemetry fallback.
- **Smart Auto-Switch**:
  - Per-bucket configurable rules (`monitoredBucketIDs` with `any`/`all` match modes) supporting **wait-for-idle** or **immediate** switching, **priority** or **round-robin** backup selection, staleness & 5h/weekly sibling safety checks, and one-time cancellation / failure pause banners.
- **Quota Warmup (Weekly & 5h)**:
  - Opt-in minimal `v1internal` SSE warmup request (`maxOutputTokens=8`) to start 7-day and 5-hour reset timers early for eligible shared Gemini & Claude/GPT pools, with active-hours and weekly-sibling (`> 5%`) safety guards, cycle-key deduplication (30-day `0600` retention), strict exclusion of dedicated pools, and manual per-account trigger.
- **`agy` CLI, `agy --hub` & Antigravity IDE 2.6+ Sync**:
  - Syncs `~/.gemini/antigravity-cli/antigravity-oauth-token` (`0600`), standalone `agy --hub` sessions, and Antigravity IDE 2.6+ shared credentials — plus **CLI-only switching** without closing Antigravity Desktop.
- **Quick Summary Header & Flexible Menu Bar UI**:
  - Displays today's token breakdown donut, cache hit %, estimated USD API cost, and aggregate pool readiness alongside **Card / Compact** views, tier & model filters, drag-and-drop ordering, account disable toggle, inline remarks, and configurable reset countdown display inside a top-anchored floating `NSPanel`.
- **Configurable Low-Quota Alerts & Companion Lifecycle Binding**:
  - Background polling (every 2 minutes) and deduplicated macOS `UNUserNotificationCenter` banners when active quotas drop below a configurable threshold (`5%–95%`, default `30%`).
  - Event-driven `AGYWatcher` LaunchAgent opens `AGY Account Switcher.app` automatically when Antigravity launches and quits when Antigravity exits externally (ignoring managed account-switch restarts).

## Project Structure

- `desktop/`: Swift Package Manager macOS SwiftUI application (`AGYAutoChanger` + `AGYWatcher`)
  - `Sources/AGYAutoChanger/App/`: App entry point & top-anchored floating `NSPanel` controller (`AGYAutoChangerApp.swift`)
  - `Sources/AGYAutoChanger/Models/`: Centralized config (`AppConfig.swift`), account/tier/policy models (`AccountProfile.swift`), quota state (`ModelUsage.swift`), switch state (`SwitchState.swift`)
  - `Sources/AGYAutoChanger/Services/Auth/`: `VaultSecurityService`, `KeychainFallbackService`
  - `Sources/AGYAutoChanger/Services/Quota/`: `CloudCodeQuotaService`, `QuotaThresholdNotifier`, `SmartAutoSwitchService`, `WeeklyWarmupService`, `UsageTrackerService`
  - `Sources/AGYAutoChanger/Services/Session/`: `AccountSwitcherService`, `AGYStateInspectorService`, `AGYRuntimeCoordinator`, `AGYCompanionLifecycleService`, `AntigravityProcessMatcher`
  - `Sources/AGYAutoChanger/Views/`: Quick Summary header & top-anchored popover (`MenuBarPopoverView`), Card/Compact cards (`AccountCardView`), add/import account sheet (`AddAccountSheetView`), inline settings (`SettingsInlineView`)
  - `Sources/AGYWatcher/main.swift`: Lightweight background launcher helper bundled at `Contents/Helpers/AGYWatcher`
  - `Tests/AGYAutoChangerTests/`: Domain-aligned XCTest suites (41 tests across 7 suites)
  - `scripts/build_app.sh`: Builds release binaries and packages `desktop/build/AGY Account Switcher.app`, `.dmg`, and `.zip`
- `AGY.md`: Architecture reference

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ / Xcode Command Line Tools
- Google Antigravity Desktop (`/Applications/Antigravity.app`)
- *(Optional)* Antigravity CLI (`agy` in `~/.local/bin/agy`, Homebrew, or PATH) & Antigravity IDE 2.6+

## Build, Test & Launch

```bash
cd desktop
swift build
swift test
bash scripts/build_app.sh
open "build/AGY Account Switcher.app"
```

## Security & Privacy Notes

- All account vaults and tokens stay strictly local under `~/.agy-switcher/` (`0700` directories, `0600` files) and macOS Keychain — nothing is transmitted to third-party servers.
- Do **not** commit `~/.agy-switcher/` or Antigravity session credentials.
