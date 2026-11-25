---
title: Builder + reviewer
summary: You build in small steps; a reviewer session checks each one before you go on.
spawn: auto
max_sessions: 1
model: opus
---

1. **Start a reviewer now:**
   `kb crew start --under me --title "Reviewer" --model opus "Review the changes the lead sends you for correctness, tests and readability. Read the diff (git diff) yourself. Reply with kb crew send lead: findings ranked most severe first, or LGTM. Don't edit files."`
2. **Build in small steps.** Once `kb crew status` lists the reviewer under you, note its id. After each
   step, send it what changed and why: `kb crew send <reviewer id> "<step, files, what to look at>"`.
3. **Fix its findings** before the next step. When you disagree with one, say why in your reply to it.
4. **Sum up.** When every step is reviewed and the tests pass, sum up for the user. Never commit or push without
   their yes.
