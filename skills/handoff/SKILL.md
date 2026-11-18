---
name: handoff
description: Write a handoff note so the work can be continued from the other Claude account (for example "alice" / "bob") on this computer. Use when the user says "handoff", "передай", "сохрани для другого аккаунта", "I'm switching accounts", "лимит закончился", or before switching Claude accounts.
---

# Handoff to another Claude account

Several Claude accounts share this Windows user. Files and transcripts are shared; the sidebar is mirrored by
`share-work.ps1`. A handoff note is what the *next* session (in the other account) reads at start-up, so it must
let a fresh agent continue without re-reading this whole conversation.

1. Write the note in the user's language, in Markdown, max ~60 lines, with these sections:
   - **Goal** — what the user wants overall, in one or two sentences.
   - **Done** — what is finished and verified (files, commands, results).
   - **In progress / not verified** — what is half-done; uncommitted changes (`git status --short` if it is a repo).
   - **Next steps** — numbered, concrete, first step first.
   - **Gotchas** — decisions made, things that failed, things the user said not to do.
   - **Resume** — `claude --resume <this session id>` (the id is in `$env:CLAUDE_CODE_SESSION_ID`) and the folder.
   Do not put secrets, tokens or passwords in the note.

2. Save it (it also mirrors the sidebar to the other accounts right away). Write the body to a temp file in your
   scratchpad and pass it with `-BodyFile`:

   ```powershell
   pwsh -NoProfile -File "{{SHAREWORK_DIR}}\share-work.ps1" handoff -Cwd "<project folder>" -Title "<short title>" -BodyFile "<temp file>"
   ```

3. Tell the user, in one or two lines, where the note is and that they can now switch the account: in the other
   account the same session appears in the sidebar, and a new session in this folder gets the note as a briefing.
