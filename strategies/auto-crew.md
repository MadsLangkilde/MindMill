---
title: Auto crew
summary: You lead and start sessions under you for the parts that can run in parallel.
spawn: auto
max_sessions: 4
model: sonnet
---

You lead this task and staff it yourself.

1. **Size it up.** Read the task and the code it touches. When it is small, work alone and skip the rest.
2. **Split it** into parts that don't touch the same files. Start one session per part, at most 4:
   `kb crew start --under me --title "<part>" --model <haiku|sonnet|opus> "<brief>"`.
   Use haiku for mechanical work (renames, docs, running tests), sonnet for most building, opus for design
   and hard debugging. The brief says the goal, the files, when it is done, and to report back with
   `kb crew send lead "<what changed, what is left>"`.
3. **Coordinate.** `kb crew status` shows your sessions. Answer their questions with `kb crew send <id> …`.
   Review what each reports, integrate it, and run the tests.
4. **Report up.** When a part finishes or you are blocked, post one line to the overview session:
   `kb crew send overseer "<status>"`.
5. Ask the user only for decisions, with a choices block. Never commit or push without their yes.
