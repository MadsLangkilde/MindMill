---
name: notes
description: The user's notes in the KB that don't fit anywhere yet: write one down, talk it through (summarise, check with the user, suggest where things belong), and sort it into facts, decisions, ideas, follow-ups, references and the rest. Use for "make a note", "write this down", "let's go through my note", "where does this belong?", and when the Mindmill app sends `/mindmill:notes <action> <id>`.
allowed-tools: Bash(kb:*), Read, Edit, Grep, Glob
---

# Notes

A note is the user's own, unsorted: a thought, something they heard, a loose list. It lives in `<scope>/notes/`
(private unless the user shares it; the Overview scope holds notes that span projects) with
`status: open | filed` (filed = everything in it went where it belongs). The CLI is `kb`.

```
## Notes     what the user wrote or said, in their words
## Summary   what it comes to, as the user confirmed it
## Filed     - <section>: <title> — what went where
```

`kb note add --project <scope> --text "…" [--title "…"]` writes one down (the title defaults to its first words);
`kb note add --to <id> --text "…"` adds to one; `kb note summary <id> --text "…"` writes the confirmed summary;
`kb note filed <id> --text "<section>: <title>"` records where a part went; `kb note status <id> open|filed`;
`kb note list [--all] [--all-projects]`.

## Where things belong

Read the note, then what the KB already has on it (`kb search "<a few words>"`, the index, `kb show <id>`), so
nothing is suggested twice and a fact that changed is challenged instead (`kb fact challenge`). Then each part is one of:

- **facts**: something true about the product, the code, a system or a team that others would need;
- **decisions**: something settled, with why;
- **ideas**: something to try or build, not settled;
- **followups**: something to do or find out, with an owner when known;
- **references**: a page, document or message worth keeping;
- **architecture**: how parts fit together;
- **backlog**: a PBI or bug (use the mindmill:work-item skill's conventions);
- a goal's progress: `kb goal propose <goal id> "<what was done>"`;
- or it stays in the note.

A suggestion is an inbox entry the user adds or dismisses with one click on the note's page and in its session:
`kb inbox add --project <scope> --section <section> --proposed-by <note id> --source <note id> --title "…"
--summary "…" --reason "From your note: <a few words>" --body "…"`. What the user says yes to in the conversation
you write directly instead (`kb new <kind> …` with `--source <note id>`), then `kb note filed`.

## `discuss <id>`

Talk it through *with* the user. Often they are talking out loud (the message says the reply is read aloud): then
every reply is a few short spoken sentences, no lists, no ids, no Markdown.

1. Say back what the note comes to in two or three sentences and ask whether that's right (a choices block:
   `Yes, that's it (Recommended)` / `Not quite`). When they correct you, say it again until it's right, then
   write it with `kb note summary`.
2. Go through what's unclear, one question at a time. Add what they tell you that belongs in the note with
   `kb note add --to <id>`.
3. Along the way, when something clearly belongs somewhere ("that's a fact about the login flow"), suggest it
   in one line and ask (`Add it to Facts (Recommended)` / `Keep it in the note`); on yes write it and record it
   with `kb note filed`. Don't ask about every line: when several things fit, make them suggestions (inbox, as
   above) and say in one line that they're waiting on the note's page.
4. When it's all settled, sum up what went where in a sentence or two, and when nothing is left in the note,
   offer to mark it filed.

## `sort <id>`

Don't ask questions unless something can't be placed without the user. Read the note and the KB, make a
suggestion for each part that belongs somewhere (as above), and reply with a short list: what you suggested and
where, and what stays in the note. When the note has no summary yet, write one with `kb note summary`.

## Rules

- Nothing is created outside the KB (work items, messages) without the user's yes.
- Shared things never name KB ids or local paths; notes are private, so don't copy their text into shared entries
  beyond what the entry needs.
