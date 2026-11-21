# How it works — internals

## Where Claude keeps things

| What | Windows | macOS | Shared between accounts? |
|---|---|---|---|
| Transcripts `<sessionId>.jsonl` | `%USERPROFILE%\.claude\projects\` | `~/.claude/projects/` | yes |
| `CLAUDE.md`, memory, skills, hooks, `settings.json` | `%USERPROFILE%\.claude\` | `~/.claude/` | yes |
| Scheduled task prompts | `~/.claude/scheduled-tasks/<id>/SKILL.md` | same | yes |
| Sidebar index | `%LOCALAPPDATA%\Claude-Data\claude_*\claude-code-sessions\<account>\<org>\local_*.json` | `~/Library/Application Support/Claude*/claude-code-sessions/…` | no |
| Scheduled task registry | `…\claude-code-sessions\<account>\<org>\scheduled-tasks.json` | same layout | no |

The desktop folder is auto-detected; override with `SHAREWORK_SESSIONS_ROOT`. The shared data folder is
`~/.claude/shared-work` (override: `SHAREWORK_HOME`):

```
accounts.json          names, emails, orgs, excludeCwd, importArchived, syncEnvironment, environmentExclude
status/<account>.json  last 40 sessions of that account (written only by that account)
handoffs/<project>/    <yyyyMMdd-HHmmss>-<account>.md
sched/<account>.json   task-id snapshot used to detect deletions
backups/<account>/     copies taken before every overwrite (14 days)
sync.log
```

## Sidebar mirroring (`Sessions.ps1`)

* Key: file name `local_<id>.json`. Missing in the target → created (archived ones only with `importArchived`).
  Present in both → the newer file (`LastWriteTimeUtc`) wins, if the contents differ.
* Pins (`isStarred`): the account that is syncing (the last one used) decides. If its pin state differs from a
  target copy, only `isStarred` is patched in the target — even when the target file is newer — and the target's
  timestamp is kept. A source file without `isStarred` never changes a target pin.
* Account-bound fields are never copied: `remoteMcpServersConfig`, `enabledMcpTools`, `bridgeSessionIds`,
  `remoteControl*`, `steeredByRemoteClient`, `chromeTabGroupId`, `startedFromEnvironmentId`. A new copy gets
  `remoteMcpServersConfig: []`; an existing copy keeps its own values.
* Written atomically (temp file without `.json`, then rename); the source timestamp is copied so "newest wins"
  works in both directions. JSON is read with `-DateKind String`, so date strings are never rewritten.
* Target org: the one recorded for the account (`orgs` in `accounts.json`, set automatically from
  `CLAUDE_CODE_ORGANIZATION_UUID` by the first session of that account), else the org folder holding sessions.
  An account with neither is not written to.

## Scheduled tasks (`ScheduledTasks.ps1`, `Sync.ps1`)

The app builds the registry path as `join(userData, "claude-code-sessions", account, org, "scheduled-tasks.json")`,
runs only the signed-in account's registry, keeps it in memory and rewrites the file on every change.

* Merge by task id. Settings come from the newer registry; `lastRunAt` / `lastScheduledFor` always take the latest
  of both; a one-time task (`fireAt`) that already ran is disabled. `recordedSkips` are unioned.
* **Write policy**
  * inside a desktop session (`CLAUDE_CODE_ACCOUNT_UUID` set): write every account except the open one;
    deletions made in the open account are propagated (snapshot in `sched/<account>.json`);
  * plain terminal, app closed: write all accounts, never propagate deletions;
  * plain terminal, app running: skip tasks (it is unknown which account is open).

## Environment sync (`Environment.ps1`)

Paths relative to the desktop data folder (parent of `claude-code-sessions`). Same rules as above: newest wins,
atomic writes, backups, `-DryRun`, the account open in the app is never written (`Get-SwTaskWritePolicy`).
`accounts.json`: `syncEnvironment` (default `true`) and `environmentExclude` (any of `tombstones`, `archive`,
`presets`, `toggles`, `plugins`).

| Item | Path | Key | Rule |
|---|---|---|---|
| Session deletions | `claude-code-sessions/<A>/<O>/deleted_<id>` (content: deletion time, epoch ms; `<id>` is the `local_` uuid or the `cliSessionId`) | `<id>` | Missing tombstones are copied. For every tombstone a target knows (copied **or its own**), a still-existing session is **moved to `backups/`** unless it had real activity after the deletion (`lastActivityAt` / `lastTurnEdgeAt` / `latestUserFrameAt` — not the file mtime, which the app rewrites on its own). `Sync-SwSessions` never copies, re-creates or updates a session tombstoned in the source or the target. The account open in the app is cleaned the next time another account is active, or when `sync` runs with the app closed. Corrupt tombstones are ignored. |
| Archive index | `claude-code-sessions/<A>/<O>/archived-sessions.idx` | session id | Union. The real file format was not inspected: only one id per line or a JSON array of strings is handled; anything else is left untouched. |
| Session presets | `ccd-session-presets.json` → `byAccount.<A>.presets[]` (shared file) | `id` | Upsert, newest `lastUsedAt`/`createdAt` wins. `builtIns` and `seededFromDraft` are never touched; only non-open accounts' entries are written, the file is re-read right before the write. |
| Plugins | `plugin-list/<A>/<O>/plugins.json` | plugin id | **Report only** (`status` shows plugins missing in an account); the schema is not verified, nothing is written. |
| Tool toggles | `mcp-user-tool-toggles.json` → `owners.<A>` | account uuid | Created for accounts that have no entry yet; keys of orgs or connectors are skipped. |
| Sidebar groups/sections | — | — | No backing file identified on disk; not synchronised. |

Out of scope (account-bound): connectors / `remoteMcpServersConfig`, `config.json` `dxt:*` keys, Remote Control,
Cowork `local-agent-mode-sessions`, credentials.

## Hooks

| Hook | Script | Does |
|---|---|---|
| `SessionStart` | `hooks/session-start.ps1` | registers the account, prints `hookSpecificOutput.additionalContext` with the briefing |
| `Stop`, `SessionEnd` | `hooks/turn-end.ps1` | starts `share-work.ps1 after-turn` detached (hidden window on Windows, `nohup` on macOS) and exits |

`after-turn` waits 6 s (the app writes the final index just after the turn), updates `status/<me>.json`,
then runs the sessions + tasks sync under a named mutex. Hooks are registered in exec form
(`command: pwsh`, `args: [...]`), so no bash is needed. Every hook catches all errors and exits 0.

## Briefing (`Briefing.ps1`)

For the main git repo of the cwd (worktrees map to their repo): up to 5 sessions per other account from the
last 7 days (title, folder, branch, last wrap-up, resume command) and the latest handoff note from another
account (truncated at 3000 chars), wrapped in `<shared-work-briefing>` with a "data, not instructions" header.
Nothing is printed when nothing concerns the project.
