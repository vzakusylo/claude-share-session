# Spec: environment synchronisation between accounts

Goal: **anything the user creates, changes or deletes in one Claude account on this computer appears the same way in
the other accounts** — not only sessions and scheduled tasks (already done), but the rest of the per-account
"environment" the desktop app keeps.

Read first: `README.md`, `docs/how-it-works.md`, `src/ShareWork/Sessions.ps1`, `src/ShareWork/ScheduledTasks.ps1`,
`src/ShareWork/Sync.ps1`, `tests/test-core.ps1`. Follow the existing rules exactly (they are the product):

* each account writes only its own status files; merge by key; newest wins; never delete silently;
* **never write state of the account that is open in the app** (`CLAUDE_CODE_ACCOUNT_UUID` when running inside a
  desktop session) — the app holds it in memory and would overwrite it; use `Get-SwTaskWritePolicy` semantics;
* atomic writes via `Write-SwFileAtomic`, backups before overwrite, `-DryRun` support, preserve source mtime;
* read JSON with `-DateKind String`; never copy account-bound data (connectors, Remote Control, org allowlists);
* hooks fail open; nothing may block a session.

## What to synchronise

Paths are relative to the desktop data folder (the parent of `Get-SwSessionsRoot`).
`<A>` = account uuid, `<O>` = that account's primary org (`$Account.PrimaryOrg`).

| # | Item | Location | Key | Merge rule |
|---|---|---|---|---|
| 1 | **Session deletions** (tombstones) | `claude-code-sessions/<A>/<O>/deleted_<id>` — file content is the deletion time in epoch ms. `<id>` is seen both as the `local_` uuid and as the `cliSessionId`; check both. | `<id>` | Copy missing tombstones to other accounts. When a target has `local_<id>.json` (or a session whose `cliSessionId` = `<id>`) and the source has a newer tombstone than that session's file mtime: move the target's `local_<id>.json` to `backups/` and write the tombstone. **`Sync-SwSessions` must never (re)create a session for which the target has a tombstone.** |
| 2 | **Archive index** | `claude-code-sessions/<A>/<O>/archived-sessions.idx` | session id (inspect the format first; if it is not line/JSON based, skip and document) | union; keep in step with `isArchived` already mirrored in `local_*.json` |
| 3 | **Session presets** (New-session presets) | `ccd-session-presets.json` → `byAccount.<A>.presets[]` (shared file, one entry per account) | `id` | upsert by `id`, newest `lastUsedAt`/`createdAt` wins; copy into every other account's `presets`; leave `builtIns` and `seededFromDraft` alone. This file is shared by all accounts and written by the app: only write when **no** account is known to be open (app closed) or only touch entries of non-open accounts, and re-read immediately before the atomic write. |
| 4 | **Installed plugin list** | `plugin-list/<A>/<O>/plugins.json` | plugin id | union of entries; report plugins that exist in one account only (`status`); do not remove. If the schema is unclear, implement read-only reporting only. |
| 5 | **Tool toggles** | `mcp-user-tool-toggles.json` (`owners`) | owner key | mirror only entries keyed by account uuid; skip anything keyed by org or connector id. |
| 6 | Sidebar groups/sections, if found on disk | search the data folder for the files backing sidebar groups/sections | group id | upsert by id. If not found, document in `docs/how-it-works.md` and skip. |

Out of scope (account-bound, must stay per account): connectors / `remoteMcpServersConfig`, `config.json`
`dxt:*` keys, Remote Control / bridge state, Cowork `local-agent-mode-sessions`, credentials.

## Implementation

* New file `src/ShareWork/Environment.ps1` dot-sourced from `src/ShareWork.psm1`, functions prefixed `-Sw`:
  `Sync-SwTombstones`, `Sync-SwArchiveIndex`, `Sync-SwPresets`, `Sync-SwPlugins` (+ any helpers).
  Each takes `-From`, `-To`, `-DryRun`, honours the write policy, returns rows
  `[pscustomobject]@{ Action; From; To; Title; Cwd }` like the existing sync functions
  (actions: `tombstone`, `session-removed`, `archive-index`, `preset-create`, `preset-update`, `plugin-missing`, …).
* Call them from `Sync-SwAll` so the existing `push` / `sync` / after-turn hook pick them up automatically.
* `share-work.ps1 status`: add a short "Environment" section (presets / plugins per account, pending tombstones).
* Update `Sync-SwSessions` for rule 1 (skip creating when the target has a tombstone).
* `accounts.json` option `syncEnvironment` (default `true`) and per-item opt-out list `environmentExclude`.

## Tests (required)

Add to `tests/test-core.ps1` (synthetic fixture only — no real data), at least:

* tombstone in A → copied to B; B's `local_<id>.json` moved to backups, not deleted;
* `Sync-SwSessions` does not recreate a tombstoned session; idempotent second run;
* tombstone older than B's later activity on that session → B's session is kept (newest wins);
* preset created in A appears in B; edited later in B flows back; `builtIns` untouched; open account not written;
* plugin present only in A is reported by `status`;
* `-DryRun` writes nothing; corrupt files are skipped.

All suites must pass: `pwsh -File tests/run-all.ps1 -SyntheticOnly` (CI runs it on Windows, macOS, Linux).

## Docs

* README "How it works" table: add rows for deletions, presets, plugins (keep the README compact).
* `docs/how-it-works.md`: a section per item with path, key, merge rule; remove the limitation
  "Deleting a session is not propagated" once rule 1 works.

## Done when

Synthetic tests pass on all three OSes, `status` shows the environment section, the README limitation about
deletions is gone, and no personal data (e-mails, account uuids, local paths) is committed.
