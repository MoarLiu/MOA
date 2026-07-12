# Changelog

## 1.1.8 - 2026-07-12

- Fixed Codex usage statistics so inherited subagent history is not counted again.
- Stopped labeling model-less Codex usage events as GPT-5, and automatically rebuilt the local usage cache with the corrected model attribution.

## 1.1.7 - 2026-07-12

- Made Codex and Claude Desktop profile changes transactional so live configuration, account files, and selected state roll back together after a failed write.
- Preserved TOML multiline strings during structural edits, hardened recursive legacy-data migration and data-package integrity checks, and rejected invalid Provider Bridge ports and Codex account paths.
- Improved updater handoff cleanup, Provider Bridge streaming completion order, menu load-error visibility, and large ZCode usage-query output handling.
- Expanded regression coverage and made local build and test scripts reliably select a full Xcode toolchain when SwiftUI macros require it.

## 1.1.6 - 2026-07-10

- Refreshed GPT-5.6 pricing, adding Sol, Terra, and Luna with current standard, long-context, cached-input, and Priority rates.
- Added a daily 00:20:01 local-time pricing refresh from `models.dev`, with startup catch-up, validated incremental snapshots, and built-in pricing fallback.

## 1.1.5 - 2026-07-03

- Added a main-menu Check Update action backed by GitHub Releases.
- The updater selects the matching `arm64` or `x86_64` macOS DMG, verifies the `.sha256` checksum, backs up the current app, and installs the update.

## 1.1.4 - 2026-07-03

- Added a Codex history migration action that updates saved session `model_provider` values to the current `~/.codex/config.toml` provider.
- The migration checks for a current root `model_provider`, asks for confirmation, quits Codex before editing history state, and asks the user to restart Codex after completion.
- Added backups and automatic rollback for Codex session JSONL and SQLite history indexes if migration fails.
- Added regression coverage for missing provider config, JSONL/SQLite migration, non-standard JSONL skipping, and rollback on SQLite failure.

## 1.1.3 - 2026-06-26

- Renamed the app, bundle, package, data roots, Provider Bridge identifiers, release artifacts, and documentation from Moa-Lite to Moa.
- Updated the default Provider Bridge port to `19360` for the primary Moa identity.
- Renamed the GitHub repository to `MoarLiu/Moa`.

## 1.1.2 - 2026-06-26

- Show saved Codex official accounts with their email address, including renamed accounts such as `Plus(email@example.com)`.
- Added a default checked ZCode official mode item to the ZCode menu.
- Added a Codex official no-account option that writes `auth.json` in API key mode, keeps or selects a direct Codex API config, and saves the current login as an account when one is available.
- Disabled the Codex official restore button while the no-account option is selected.

## 1.1.1 - 2026-06-21

- Fixed Codex Official Mode restore so it preserves the selected `model_provider` value for session continuity.
- Removed third-party `base_url` and `experimental_bearer_token` values from the selected provider when restoring Codex Official Mode.
- Added regression coverage for restoring from direct third-party provider profiles such as `model_provider = "one"`.

## 1.1.0 - 2026-06-21

- Added a ZCode menu with usage statistics, launch/relaunch actions, and quick access to `~/.zcode`.
- Added ZCode usage scanning from the local CLI SQLite database with GLM-5.2, GLM-5.1, and GLM-5-Turbo pricing.
- Added cache hit ratio to Codex, Claude Desktop, and ZCode usage summaries and insights.
- Localized new ZCode and cache-hit UI strings in English and Simplified Chinese.

## 1.0.0

- Created Moa as an independent macOS menu bar app.
- Kept Codex, Claude Desktop, Provider Bridge, local usage insights, data package import/export, diagnostics, and iCloud data-root switching.
- Removed Companion, desktop pet, AI quick actions, reminders, journal, Pomodoro, MCP helper, workflow runner, asset upload, updater, dashboard, skins, and sounds.
- Restored trimmed English and Simplified Chinese localization bundles for the Moa menu and dialogs.
- Standardized the app identity and data paths as Moa: `Moa.app`, `com.moarliu.moa`, `~/.moa`, `iCloud Drive/Moa`, `moa-*` Codex provider IDs, and Provider Bridge port `19360`.
- Replaced legacy Moa integration tests with Moa focused core tests.
