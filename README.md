# claude-share-session

**Continue the same Claude Code work from several Claude accounts on one Windows PC.**

You sign in to the Claude desktop app with account A, work on a few projects, then switch to account B —
and the sidebar is empty: "different projects". This tool makes every account see the same sessions,
the same scheduled tasks and a short briefing of what the other account just did, so you can pick up
exactly where you left off.

![How claude-share-session works](docs/infographic.png)

> Windows 11 · macOS (beta) · Claude desktop app (Code tab) and Claude Code CLI · PowerShell 7 · no services, no cloud, no network.

---

## Why the work looks "different" after switching

Claude Code stores almost everything per **Windows user**, not per Claude account:

| What | Where | Shared between accounts? |
|---|---|---|
| Session transcripts (`<sessionId>.jsonl`) | `%USERPROFILE%\.claude\projects\` | **Yes** |
| `CLAUDE.md`, memory, skills, hooks, `settings.json` | `%USERPROFILE%\.claude\` | **Yes** |
| Scheduled task prompts (`SKILL.md`) | `%USERPROFILE%\.claude\scheduled-tasks\<id>\` | **Yes** |
| **Desktop sidebar** (list of sessions) | `%LOCALAPPDATA%\Claude-Data\claude_*\claude-code-sessions\<account>\<org>\local_*.json` | **No** — one list per account |
| **Scheduled task registry** (schedule, on/off, last run) | `…\claude-code-sessions\<account>\<org>\scheduled-tasks.json` | **No** — the app runs only the signed-in account's tasks |
| Connectors, Remote Control | account / organization | No (and should not be) |

So the conversations themselves are already on disk for every account. Only two small per-account
indexes are separate. `claude-share-session` mirrors those indexes and adds a light coordination layer.

## What it does

1. **Mirrors the sidebar.** After every turn, the sessions of the account you are using are copied into the
   sidebar of the other accounts. Open the same session in the other account and keep typing — the full
   context is there, because the transcript file is shared.
2. **Mirrors scheduled tasks.** A task created in account A also exists in account B, so it fires in whichever
   account is open. The latest "last run" always wins, so a run that already happened is never repeated.
3. **Briefs every new session.** When a session starts in a project, it gets a short note: which other account
   worked here, when, on which branch, what the last turn ended with, the `claude --resume` command, and the
   latest handoff note. The note is marked as *data, not instructions*.
4. **`/handoff` skill.** Before switching, type `/handoff`. The agent writes a short note (goal, done,
   not verified, next steps, gotchas, resume command) for the next account.
5. **`/shared-work` skill.** Ask "what did the other account do here?" or "sync accounts".

Design ideas borrowed from multi-agent coordination tools (e.g. team-sync):

* every writer writes **only its own file** (`status\<account>.json`, `handoffs\…\<time>-<account>.md`) — no write conflicts;
* merge **by key** (session id / task id), **newest wins**, never delete silently;
* briefings from other sessions are **data**, never executed without the user confirming;
* coordination hooks **fail open**: on any error they exit 0 and never block your session.

---

## Scenario: two small subscriptions instead of one big one

You buy two smaller Claude plans (for example two Pro accounts) and use them on one PC with one Windows user,
for example in two Chrome profiles for the web and one desktop app for Claude Code.

**Monday morning, account A**

1. Open the desktop app as **A**, work in `C:\work\shop-api` and `C:\work\landing`.
2. After every turn the hook mirrors your sessions into B's sidebar in the background.

**Afternoon: A hits its usage limit**

3. In the running session type `/handoff`. The agent saves a note: what is done, what is half-done,
   the next three steps.
4. Switch the desktop app to account **B** (sign out → sign in, or account switcher).
5. B's sidebar already contains *the same* sessions. Open the `shop-api` session and write
   "continue" — Claude has the whole conversation, and the handoff note is in the shared folder.
   Or start a fresh session in `C:\work\shop-api`: it receives the briefing automatically:

   ```
   <shared-work-briefing>
   You are running as Claude account 'bob'. …
   Account 'alice' worked in this project recently:
   - 2026-11-18 14:05  "Checkout API refactor"  [branch feat/checkout]  (claude --resume 6f1c…)
       last state: tests green, migration not applied yet
   Latest handoff note from 'alice': …
   </shared-work-briefing>
   ```

**Evening: scheduled task**

6. A daily task "Morning report at 08:00" was created in A. Tomorrow you start the day in B — the task fires
   in B, because its registry entry was mirrored. Tomorrow evening you are back in A: A knows it already ran.

**Next day, back to account A**

7. Switch back. Everything B did is in A's sidebar (B pushed it after each of its turns).

Rules of thumb:

* Use **one account at a time** for the same session (switching is fine, running both at once is not:
  the transcript is a single file).
* Each account spends **its own** quota; the tool does not bypass any limit, it only lets you continue the
  same work. Check that your use of several subscriptions fits Anthropic's terms for your plan.
* Archive sessions instead of deleting them (deletes are not propagated, a deleted session comes back from
  the other account).

---

## Install

Requirements: Windows 10/11, Claude desktop app with the Code tab, [PowerShell 7](https://aka.ms/powershell),
Git, Node.js (only for the optional fidelity test).

1. Sign in to the desktop app **once with every account** and open at least one Code session in each
   (this creates the account's folder).
2. Clone and install:

   ```powershell
   git clone https://github.com/vzakusylo/claude-share-session.git C:\tools\claude-share-session
   pwsh -NoProfile -File C:\tools\claude-share-session\install.ps1
   ```

   The installer

   * backs up `%USERPROFILE%\.claude\settings.json` (`settings.json.bak-sharework-<time>`) and adds three hooks
     (`SessionStart`, `Stop`, `SessionEnd`) that call `pwsh` directly (no bash needed);
   * installs the skills `/handoff` and `/shared-work` into `%USERPROFILE%\.claude\skills`;
   * prints `status`.

   Hooks and skills live in the shared `~/.claude`, so they work in **all** accounts at once.

3. Give the accounts names (optional — otherwise the part of the e-mail before `@` is used once the account
   runs its first session):

   ```powershell
   pwsh -NoProfile -File C:\tools\claude-share-session\share-work.ps1 status
   pwsh -NoProfile -File C:\tools\claude-share-session\share-work.ps1 name 1a2b3c4d alice
   pwsh -NoProfile -File C:\tools\claude-share-session\share-work.ps1 name 5e6f7a8b bob
   ```

   or map e-mails to names in `%USERPROFILE%\.claude\shared-work\accounts.json` → `"emails"`.

4. First sync (preview first):

   ```powershell
   pwsh -NoProfile -File C:\tools\claude-share-session\share-work.ps1 sync -DryRun
   pwsh -NoProfile -File C:\tools\claude-share-session\share-work.ps1 sync
   ```

   Sessions added to the account that is open right now appear after you switch accounts or restart the app.

Uninstall: `install.ps1 -Uninstall` (removes hooks and skills; mirrored sessions and the data folder stay).

## macOS

The same code runs on macOS with PowerShell 7 — there is no separate implementation.

```sh
brew install powershell git
git clone https://github.com/vzakusylo/claude-share-session.git ~/tools/claude-share-session
cd ~/tools/claude-share-session
chmod +x install.sh share-work.sh
./install.sh
./share-work.sh status
./share-work.sh sync -DryRun
./share-work.sh sync
```

What differs on macOS:

| | Windows | macOS |
|---|---|---|
| Shared Claude Code folder | `%USERPROFILE%\.claude` | `~/.claude` |
| Desktop session index (auto-detected) | `%LOCALAPPDATA%\Claude-Data\claude_*\claude-code-sessions` | `~/Library/Application Support/Claude*/claude-code-sessions` |
| Hook launcher | `pwsh.exe` | `pwsh` (Homebrew), background step detached with `nohup` |
| Lock | named mutex | named mutex (.NET on Unix) |

If `status` says the `claude-code-sessions` folder was not found, find it once and point the tool at it:

```sh
find ~/Library/Application\ Support -maxdepth 3 -type d -name claude-code-sessions
export SHAREWORK_SESSIONS_ROOT="<that folder>"   # add to ~/.zshrc
```

> The macOS desktop folder layout is inferred from the Windows build (same Electron app); it was **not
> verified on a Mac yet**. The Claude Code part (`~/.claude/projects`, hooks, skills) is the same on both.
> Please open an issue with the output of `./share-work.sh status` if something differs.

## Commands

```
share-work.ps1 status            accounts, sessions, scheduled tasks, what is not mirrored yet
share-work.ps1 brief             briefing for the current folder (what a new session would get)
share-work.ps1 resume            recent sessions of all accounts in this project + claude --resume
share-work.ps1 push [-DryRun]    current account -> other accounts
share-work.ps1 sync [-DryRun]    two-way between all accounts
share-work.ps1 handoff -Title t -BodyFile f   save a handoff note (the /handoff skill uses this)
share-work.ps1 name <uuid> <n>   name an account
share-work.ps1 log               last lines of the sync log
```

Settings (`%USERPROFILE%\.claude\shared-work\accounts.json`):

* `names` — account uuid → name; `emails` — e-mail → name for new accounts;
* `excludeCwd` — folder masks that are never mirrored, e.g. `"C:\\work\\client-x\\*"`;
* `importArchived` — `true` to mirror archived sessions too.

## How it works

```
 Account A (open in the app)              shared folder %USERPROFILE%\.claude\shared-work
 ─────────────────────────                ──────────────────────────────────────────────
 end of each turn ── Stop hook ─(0.6 s)─► background, 6 s later:
                                            status\A.json      (A's recent sessions: project, branch, last state)
                                            A's local_*.json   ──► sidebar of B, C …
                                            A's task registry  ──► registry of B, C …
 /handoff ──────────────────────────────► handoffs\<project>\<time>-A.md

 Account B (after switching)
 ─────────────────────────
 sidebar already has A's sessions ──► open, continue (transcript is shared)
 new session ── SessionStart hook ──► <shared-work-briefing> with A's work + latest handoff
```

### Sidebar mirroring

* creates missing sessions (archived ones only with `importArchived`), updates existing ones when the other
  copy is newer (file time), never deletes;
* account-bound fields (`remoteMcpServersConfig`, `bridgeSessionIds`, Remote Control, Chrome tab group …)
  are not copied; an existing copy keeps its own;
* atomic writes (temp file without `.json` → rename) so the app never reads half a file; the source
  timestamp is preserved so "newest wins" works both ways;
* backup before every overwrite in `shared-work\backups\<account>\<date>\` (kept 14 days);
* from the hook it writes **only into accounts that are not open**, so it never fights with the running app.

### Scheduled tasks

The desktop app builds the registry path as
`join(userData, "claude-code-sessions", account, org, "scheduled-tasks.json")`, keeps it in memory and rewrites
it on every change. Therefore:

* merged by task id; settings (schedule, enabled, title, permissions) come from the newer registry;
* `lastRunAt` / `lastScheduledFor` always take the latest of both → no repeated "catch-up" run after switching;
  a one-time task that already fired is disabled everywhere;
* the registry of the account **open in the app is never written** (the app would overwrite it);
* a deleted task is removed elsewhere only when it is certain that the open account deleted it (hook inside a
  desktop session); from a plain terminal a missing task is never treated as deleted, and with the app running
  a plain-terminal `sync` skips tasks entirely — use `/shared-work` instead;
* the project of a session is its git main repo, so a session in `repo\.claude\worktrees\x` counts for `repo`.

### New accounts

A new account is picked up automatically: after its first sign-in it gets a folder in `claude-code-sessions`,
and its first session records its organization and name. Until its organization is known nothing is written
into it.

## Files

| File | Purpose |
|---|---|
| [src/ShareWork.psm1](src/ShareWork.psm1) | all logic: accounts, mirroring, tasks, status, handoff, briefing |
| [share-work.ps1](share-work.ps1) | command line |
| [hooks/session-start.ps1](hooks/session-start.ps1) | briefing at session start |
| [hooks/turn-end.ps1](hooks/turn-end.ps1) | starts the background status + push after each turn |
| [skills/handoff](skills/handoff/SKILL.md), [skills/shared-work](skills/shared-work/SKILL.md) | the two skills |
| [install.ps1](install.ps1) | install / uninstall |
| [tests/compare-mirror.js](tests/compare-mirror.js) | checks mirrored sessions equal the originals |
| [tests/test-scheduled.ps1](tests/test-scheduled.ps1) | 16 scenario checks for task mirroring, on a copy of your data |

| [tests/test-core.ps1](tests/test-core.ps1) | 65 checks on a synthetic fixture: accounts, mirroring, project keys, status, handoff, briefing, registration, hooks, installer, CLI |
| [tests/run-all.ps1](tests/run-all.ps1) | runs every suite; real-data suites only if the desktop app data exists |

Run the tests:

```powershell
pwsh -NoProfile -File tests/run-all.ps1                 # everything available on this machine
pwsh -NoProfile -File tests/run-all.ps1 -SyntheticOnly  # no real data touched (what CI runs)
```

| Suite | Data | What it checks |
|---|---|---|
| `test-core.ps1` | synthetic, temp folder | 65 checks: account discovery, create/update/skip rules, account-bound fields, unicode, ISO dates, mtime, archived/excluded, corrupt files, worktree → repo, status cap/dedupe, handoff front matter, briefing content/limits/age, auto-registration, hooks fail-open and speed, installer idempotency and uninstall, CLI |
| `test-scheduled.ps1` | copy of your real data | 16 scheduled-task scenarios: create, idempotent, run state, rename, newest config, latest run wins, one-time tasks, active account never written, deletes |
| `compare-mirror.js` | your real data, read-only | every mirrored session equals its original except account fields (in-flight sessions skipped) |

GitHub Actions runs the synthetic suite on Windows, macOS and Linux for every push.

## Limitations

* `local_*.json` and `scheduled-tasks.json` are **internal formats** of the desktop app and may change in a
  new version. Tested with Claude desktop 4.23118 and Claude Code 2.1.317. That is why there are backups and
  `-DryRun`.
* Windows is tested; macOS support uses the same code and is not yet verified on a real Mac (see [macOS](#macos)).
* Not affiliated with Anthropic. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
