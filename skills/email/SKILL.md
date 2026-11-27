---
name: email
description: Scan the user's new email for things they must do or should remember, and propose them as reminders (or as project knowledge for the inbox), skipping newsletters, marketing and tool notifications. Use for "check my email for todos", "scan my mail", "did I miss anything in email", from the morning routine, and when the Mindmill app's email sync starts it.
allowed-tools: Bash(kb:*), Read, Edit, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__read_resource
---

# Scan email

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). Nothing you find is added for real: reminders are
**proposed** (`--proposed`) and the user accepts or dismisses each one in the app. **Be selective.** The user
gets a lot of mail they don't need to act on, and a list of 20 proposals is worse than none.

## 1. Where to start

`kb email state` prints `since` (the last scan, or 3 days ago), the `ignore` list (domains, sender names and
words the user never wants), and `reminder_sources` (emails already turned into reminders).

## 2. Read the new mail

Read the mail tool `kb tools` names, never another that happens to be connected (none set: reply
`ERROR No mail tool is set in Mindmill (Settings → Connections → What you use).`). Search for messages received
after `since` in the inbox, newest first, 25 per page, at most 4 pages (Microsoft 365: `outlook_email_search`;
Gmail: a search like `in:inbox after:<date>`). Read a message in full (Microsoft 365: `read_resource`) only
when the preview isn't enough to judge it.

If the tool is missing, needs sign-in or fails, stop and reply `ERROR <reason>` (add "Run `/mcp` and sign in to
<the connector>" when it needs sign-in). Don't run `kb email scanned`.

## 3. Keep or skip

**Skip without a second look:**
- a sender or domain matching an `ignore` entry, or an email already in `reminder_sources`
- newsletters, digests, marketing, webinars, product updates, surveys (Postman, Medium, LinkedIn and the like)
- automated notifications about things the morning routine already covers: pull requests, builds,
  work items, calendar invitations and acceptances
- mail where the user is only in CC and nobody asks them anything
- anything already handled: the user replied later in the thread, or a newer mail resolves it

**Keep**, when it asks the user to do something or carries a date they must not miss:
- a mandatory or assigned training, course, certification or e-learning, with its deadline
- a direct request or a question someone is waiting on
- an approval, form, timesheet, expense, HR or IT action; a renewal or an expiring access
- an event the user signed up for that needs preparation

**Project knowledge** (a decision, a contract detail or a date that matters to a registered project, not a
to-do): `kb inbox add --project <p> --section facts|decisions --proposed-by email:<id> --reason "<one line>" …`.

**A discussion** (several people going back and forth about something in a registered project that isn't
settled: a design question, a requirement, a disagreement, an open problem) is tracked, not turned into a
reminder. `kb discussion list --all-projects --json` shows the open ones with their `thread`:
- the thread is already tracked: add the new messages' points to it as the mindmill:discussion skill's `refresh` does
  (`kb discussion note <id> --who … --date … --text …`, `--kind question|finding`, `--waiting-on`);
- it is new: create it as the skill's `start` step 3–4 does, in the scope it belongs to (`--cross-project` when
  needed), with `channel=email`, `thread=<conversation id>` and `link=<webLink>`.
Set `waiting_on=me` when someone asks the user directly. Add a reminder as well only when there is a deadline.

## 4. Propose

For each email you keep, one reminder, with the note on stdin:

```sh
kb reminder add --proposed --title "<imperative, ≤10 words>" --due <YYYY-MM-DD> \
  --source email:<message id> --from "<sender name>" --from-domain <domain> --link "<webLink>" \
  --reason "<why this needs the user, one line>" [--project <p>] --body-stdin <<'NOTE'
<2–3 lines: what is asked, by whom, the deadline as written in the mail>
NOTE
```

- **Due:** the deadline in the mail; for a long deadline, a week before it. With no date, tomorrow for a
  direct ask, otherwise in a week.
- **No email addresses** in any command, only names and the domain. A privacy hook may refuse a command that
  contains the user's address. If one refuses anyway, reply `ERROR <the reason>`; don't get around it.
- Set `--project` only when it clearly belongs to one registered project.

## 5. Finish

`kb email scanned` (records now as the last scan). Reply with one line:
`EMAIL <n> proposed, <m> skipped, <d> discussions updated` and, when you proposed any, the most urgent one in ≤12 words.
