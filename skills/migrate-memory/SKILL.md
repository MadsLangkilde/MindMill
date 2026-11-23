---
name: migrate-memory
description: Move project knowledge out of Claude Code's auto-memory into the knowledge base, in batches the user approves. Use when the user asks to migrate, import or move memories into the KB.
allowed-tools: Bash(kb:*), Read, Glob, Grep
---

# Migrate auto-memory into the knowledge base

Auto-memory lives in `~/.claude/projects/<encoded cwd>/memory/` with an index `MEMORY.md`. After the
migration it keeps only **feedback** (how Claude should work for this user). Project knowledge moves to the KB.

## Classify every memory file

| Memory | Goes to |
|---|---|
| `type: feedback` | stays in auto-memory |
| a decision someone made (team decision, meeting outcome, an agreed contract) | `decisions/` (date = when decided) |
| a durable fact: a quirk, an external constraint, a reference URL, a gotcha in a library | `facts/` |
| how a part of the system works | `architecture/` |
| work-item status (PR open/merged, worktree present, device pass pending) | **ask**: most of it is stale the moment it's written and belongs in the tracker. Default: skip, keeping only the durable gotchas inside as facts |
| an archive index | skip |

Pick the project per entry: this repo's project, or the shared one (e.g. `product`) when it holds for several
apps. Never copy one entry into two projects.

## Batches

1. Read `MEMORY.md` and propose batches of **at most 10** files, grouped by theme. Per file, one line:
   `<file> → <section>/<slug> in <project>` or `→ stays (feedback)` or `→ skip (status)`.
2. Wait for the user's yes or corrections.
3. For each approved file: read it, rewrite it as a KB entry. Keep facts, dates, ids and the **Why**, and
   cut narration and status that has expired. Write it with `kb new … --body-stdin`, using the memory's
   date where it has one. Facts that cite code must still be true; check with a quick grep and mention
   anything that has gone stale instead of copying it.
4. After the batch is written: delete the migrated memory files and remove their lines from `MEMORY.md`.
   Ask before deleting the first batch. Later batches follow the same rule once the user has said yes.
5. `kb lint`, report the ids written and what was skipped, then offer the next batch.

Never delete a memory whose KB entry wasn't written successfully.
