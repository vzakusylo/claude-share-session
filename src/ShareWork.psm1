#requires -Version 7.2
<#
  ShareWork — shared Claude Code work for several Claude accounts on ONE Windows user.

  Facts this module is built on (verified on this machine, Claude desktop 4.23118):
    * Transcripts of every Code session live in %USERPROFILE%\.claude\projects\<enc-cwd>\<cliSessionId>.jsonl.
      They are shared by all accounts already (same Windows user, same ~/.claude).
    * The desktop sidebar is a per-account index:
        %LOCALAPPDATA%\Claude-Data\claude_*\claude-code-sessions\<accountUuid>\<orgUuid>\local_<id>.json
      Only this index differs between accounts — that is why "projects are different" after switching.

  Ideas borrowed from team-sync (nikulinsanya/hackaton-tool):
    * every writer owns its own file (status\<account>.json, handoffs\...\<ts>-<account>.md) -> no write conflicts;
    * merge by key (session id), newest wins;
    * a short briefing of "who did what here" is injected at session start; it is DATA, never instructions;
    * coordination hooks fail open (never block a session).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fields of a session index that belong to the account/org, not to the work itself.
# They are never copied to another account; on update the target's own values are kept.
$script:AccountBoundKeys = @(
    'remoteMcpServersConfig', 'enabledMcpTools', 'bridgeSessionIds', 'remoteControlUserEnabled',
    'remoteControlAutoEligible', 'steeredByRemoteClient', 'chromeTabGroupId', 'startedFromEnvironmentId'
)
# scheduledTaskId is NOT account-bound any more: scheduled tasks are mirrored too (Sync-SwScheduledTasks),
# so a run's session keeps its link to the task in every account.

# Run-state fields of a scheduled task: always merged as "latest wins", whichever registry is newer,
# so a run that already happened in one account is never repeated as a catch-up run in the other.
$script:TaskRunStateKeys = @('lastRunAt', 'lastScheduledFor')


# Each file holds one area; order matters only for readability (functions resolve at call time).
foreach ($part in 'Config', 'Accounts', 'Projects', 'Sessions', 'ScheduledTasks', 'Environment', 'Sync', 'Status', 'Handoffs', 'Briefing') {
    . (Join-Path $PSScriptRoot "ShareWork/$part.ps1")
}

Export-ModuleMember -Function *-Sw*