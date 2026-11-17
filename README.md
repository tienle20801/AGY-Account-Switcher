# AGY Account Switcher

Native macOS Menu Bar (`MenuBarExtra`) utility for **1-click Google Antigravity (AGY) account switching**, **real-time multi-bucket quota tracking**, **low-quota macOS alerts**, and **companion lifecycle sync**.

## Features

- **1-Click Atomic Account Switching** (`⌘1`–`⌘9`):
  - Flushes telemetry and snapshots outgoing session files (`0700`/`0600` vault under `~/.agy-switcher/`) and `go-keyring` / Keychain OAuth credentials before safely terminating Antigravity + `language_server`, swapping snapshots atomically with rollback protection, and relaunching Antigravity.
  - Supports **Clean Login** flow to sign into additional accounts without wiping saved profiles or workspace layouts.
- **Live Multi-Bucket Quota Tracking**:
  - Tracks **Gemini 5h / Weekly**, **Claude & GPT 5h / Weekly**, and **Gemini 4 Argon Weekly** remaining percentages and reset countdowns.
  - Combines fast Cloud Code REST endpoints (`/v1internal:loadCodeAssist`, `/v1internal:retrieveUserQuotaSummary`, `/v1internal:retrieveUserQuota`, `/v1internal:fetchAvailableModels`), official Antigravity CLI (`agy -p /usage --output-format stream-json`) for dedicated Argon quota, and strictly read-only SQLite + `transcript.jsonl` telemetry fallback.
- **Configurable Low-Quota Alerts**:
  - Background polling (every 2 minutes) and deduplicated macOS `UNUserNotificationCenter` banners when active **Argon** or **Gemini** buckets drop below a configurable threshold (default `30%`, toggleable and customizable `5%–95%` in Settings).
- **Companion Lifecycle Binding**:
  - Event-driven `AGYWatcher` LaunchAgent opens `AGY Account Switcher.app` automatically when Antigravity launches and quits when Antigravity exits externally (ignoring managed account-switch restarts).

## Project Structure

- `desktop/`: Swift Package Manager macOS SwiftUI application (`AGYAutoChanger` + `AGYWatcher`)
  - `Sources/AGYAutoChanger/App/`: App entry point & MenuBarExtra window
  - `Sources/AGYAutoChanger/Models/`: Centralized config (`AppConfig.swift`), account/tier models, quota state
  - `Sources/AGYAutoChanger/Services/Auth/`: `VaultSecurityService`, `KeychainFallbackService`
  - `Sources/AGYAutoChanger/Services/Quota/`: `CloudCodeQuotaService`, `QuotaThresholdNotifier`, `UsageTrackerService`
  - `Sources/AGYAutoChanger/Services/Session/`: `AccountSwitcherService`, `AGYStateInspectorService`, `AGYCompanionLifecycleService`, `AntigravityProcessMatcher`
  - `Sources/AGYAutoChanger/Views/`: Popover UI, compact auto-sizing cards, inline add-account & settings panels
  - `Sources/AGYWatcher/main.swift`: Lightweight background launcher helper bundled at `Contents/Helpers/AGYWatcher`
  - `Tests/AGYAutoChangerTests/`: Domain-aligned XCTest suites
  - `scripts/build_app.sh`: Builds release binaries and packages `desktop/build/AGY Account Switcher.app`
- `AGY.md`: Architecture reference

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ / Xcode Command Line Tools
- Google Antigravity Desktop (`/Applications/Antigravity.app`)
- *(Optional, for dedicated Argon quota polling)* Antigravity CLI (`agy` in `~/.local/bin/agy`, Homebrew, or PATH)

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
