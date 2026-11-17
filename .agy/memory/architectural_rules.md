# Architectural Rules

1. **Clean Root Invariant**: Root directory may only contain `AGY.md`, `README.md`, `.gitignore`, `.agy/`, and `desktop/`. No stray build artifacts, logs, or scripts at root.
2. **Centralized Configuration**: All paths, model definitions, tier quotas, and timeouts live in `Models/AppConfig.swift`.
3. **Security & Vault Isolation**:
   - Vault root `~/.agy-switcher` and profile subdirectories use `0o700` POSIX permissions.
   - `accounts.json` and snapshot auth files use `0o600` POSIX permissions.
   - Never log raw OAuth tokens, cookies, or credential payloads.
   - Atomic snapshot restoration always creates a rollback backup first and removes stale `-wal`/`-shm` SQLite sidecars.
4. **Concurrency & RunLoop**:
   - `AccountSwitcherService` runs on `@MainActor`.
   - File I/O, process termination polling, and SQLite inspection avoid blocking the UI thread.
   - Timers use `.common` RunLoop mode or Swift Concurrency `Task` loops.
