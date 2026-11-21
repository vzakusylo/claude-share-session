---
name: export-projects-to-folders
description: Mirror claude.ai projects to local folders - one folder per project, one subfolder per chat holding the files that chat produced, plus instructions and a library (kb) copy. Use when asked to export, back up or copy projects/chats/library files from claude.ai to disk or push them to GitHub.
---

# Export claude.ai projects to local folders

Target layout (example: `~/Claude`, on Windows `%USERPROFILE%\Claude`):

```
<root>\<Project>\
  INSTRUCTIONS.md          project instructions text
  kb\                      copy of the library files (deduped from chat downloads)
  <Chat title>.md          handoff note for EVERY chat (goal, done, key points, open items, chat URL)
  <Chat title>\            one folder per chat that produced files
      <file>.md / .zip     files downloaded from that chat's file cards
```

## Procedure
1. **Folders.** Get the project list from claude.ai/projects (get_page_text). `device_request_folder_access` on the root, then `mkdir -p` one folder per project name (keep the Claude names). Skip protected folders such as `Artifacts`.
2. **Chat list.** Open the project page and read the Recents list. Chat titles become file/folder names (keep Cyrillic/emoji-free titles, strip emoji prefixes, no `…` issues: keep as shown).
3. **Handoffs.** For each chat, open it, `get_page_text`, and write `<Chat title>.md` with: project, last activity, chat URL, goal, what was done, key points, open questions. Do this for every chat, including scheduled-task chats.
4. **Files per chat.** In each chat that shows file cards (`Document · MD`, `ZIP`):
   - click the card to open the preview on the right;
   - for MD: click the **Copy dropdown arrow at ~(1012,22)**, wait 1 s, then **"Download as MD" at ~(925,62)**;
   - for ZIP: click the **download icon at ~(1011,22)** in the preview toolbar;
   - always zoom on the preview header first to confirm which file is open.
5. **Move downloads.** Chrome saves them in `Downloads` with a `.crdownload` suffix and names like `README (3).md`. Request access to `~/Downloads`, then copy under the real name (strip ` (n)` and `.crdownload`) into the chat's folder. Ignore `*.tmp` files (other downloads). Verify with `head -1` / file size (ZIP: `python3 -c "import zipfile..."`); redo if the content is the wrong file.
6. **Library (kb).** Project library previews have NO download (menu only has Remove; Select mode only deletes). Build `kb\` from the chat downloads instead: entries, README and weekly-log from the newest chat, `news\` from digest chats. Say clearly that it is a rebuilt copy.
7. **Instructions.** Click Edit on the Instructions card, read the text (screenshot/zoom for short text), write `INSTRUCTIONS.md`, then press **Cancel**, never Save.
8. **Report** what was copied and the gaps (files "no longer available", pictures skipped, chats with no files).

## Pitfalls learned
- `javascript_tool` and `fetch('/api/...')` are blocked on claude.ai unless the user approves; use find / read_page / get_page_text / clicks.
- `find` refs go stale after every navigate; re-run `find` each time. Use `browser_batch` for click sequences.
- `read_page` and `find` cut every line at ~100 characters, so never use them to copy file contents.
- Do a short wait after opening the Copy menu, otherwise the download click misses.
- Layout changes when the Runs side panel is open (scheduled chats): take a screenshot before clicking cards.
- Deleting in a connected folder is "Operation not permitted": move to `_to_delete/` instead.
- Do not download pictures unless asked. Ask before bulk downloads and before reading Downloads.
- Shell on the device has no `gh`; the cloud workspace cannot create repos. For GitHub, the user creates the empty repo, then runs `git init -b main`, `.gitignore` (`Artifacts/`), commit, `git remote add origin`, and `git pull origin main --allow-unrelated-histories` if the push is rejected.
- Chats on models that now need credits (e.g. Fable) still open and can be read.
