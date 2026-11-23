---
name: ask
description: Answer a question about a project from every knowledge source it has: the knowledge base, the code and docs, related projects, and configured sources such as the Azure DevOps wiki, work items and repos, Teams, email, documentation sites, MCP servers and custom commands. Cites each claim. Use for "what do we know about…", "why does…", "who decided…", "where is … documented", "ask the KB", and every question sent from the Mindmill app's Ask panel.
allowed-tools: Bash(kb:*), Bash(curl:*), Bash(git:*), Read, Grep, Glob, WebFetch, WebSearch, mcp__claude_ai_Microsoft_365__chat_message_search, mcp__claude_ai_Microsoft_365__teams_list_chats, mcp__claude_ai_Microsoft_365__teams_list_channel_messages, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__read_resource, mcp__claude_ai_Microsoft_365__sharepoint_search
---

# Ask the knowledge sources

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). Source kinds are described in
`${CLAUDE_PLUGIN_ROOT}/docs/format.md` under "Knowledge sources".

## 1. Pick the sources

`kb sources list --project <p> --json` gives every source for the project: built-ins (`kb`, `code`,
`related:<id>`), the project's own, and global ones. Skip `enabled: false`. If the message says
`Use only these sources: …`, use exactly those.

Route on each source's `use_for`. Start with the cheapest sources that are most likely to answer:

1. `kb`: `kb search <terms> --project <p>`, then `kb show` the hits. Decisions in force beat everything
   else on "what did we decide". Hits in `references/` are saved copies of artifacts, emails, chats,
   pages and documents: cite them like any entry, with the `captured` date when it matters how fresh it is.
2. `code`: Grep/Read under its path. The code is the truth for "how does it work today".
3. Configured sources whose `use_for` matches the question.
4. `related:<id>`: only when the question is about another project or cross-platform parity.

Stop as soon as the answer is solid. When sources disagree, say so and show both.

## 2. Read each kind

| Kind | How |
|---|---|
| `kb` | `kb search`, `kb show`, or Read under `config.path` |
| `folder`, `related` | Grep/Glob/Read under `config.path` / `config.paths` |
| `url` | WebFetch `config.url`; with `scope: site`, WebSearch `site:<host> <terms>` first |
| `ado-wiki` | `POST https://almsearch.dev.azure.com/{org}/{project}/_apis/search/wikisearchresults?api-version=7.1` `{"searchText": "...", "$top": 5}`, then read a page with `GET https://dev.azure.com/{org}/{project}/_apis/wiki/wikis/{wiki}/pages?path=<path>&includeContent=true&api-version=7.1`. PAT from `~/.git-credentials` (`curl -u ":$PAT"`). Cite the web URL `https://dev.azure.com/{org}/{project}/_wiki/wikis/{wiki}?pagePath=<path>`. |
| `ado-work-items` | WIQL (`POST …/_apis/wit/wiql?api-version=7.1`) on title and description, then `GET …/_apis/wit/workitems?ids=…&$expand=all`. Cite `ado:<id>` with its `_workitems/edit/<id>` URL. |
| `ado-repos` | Code search `POST https://almsearch.dev.azure.com/{org}/{project}/_apis/search/codesearchresults?api-version=7.1`; PRs and threads via `…/_apis/git/repositories/{repo}/pullrequests`. |
| `teams` | Microsoft 365 `chat_message_search` (respect `chats`/`channels`/`since_days`), then read the thread. Cite the chat and the date. |
| `outlook` | Microsoft 365 `outlook_email_search` (respect `folders`/`since_days`). Cite the subject, sender and date. |
| `mcp` | The `config.server` tools (`mcp__<server>__*`, or the listed `tools`). |
| `command` | `kb sources test <id> --project <p> --query "<terms>"` runs it and prints the output. |

`kb sources test` also works for `folder`, `url` and the `ado-*` kinds when you just need a quick list of hits.

## 3. Answer

```
<the answer, direct, first sentence answers the question; [n] after each claim>

Sources:
[1] <source id> — <entry id | file path | URL | ado:<id>> — <title>
[2] …
```

- Every claim gets a citation. No citation, no claim. If nothing answers it, say what you searched and
  suggest where the answer might live (a person, a source that isn't configured yet).
- Mark anything that comes only from a related project or from Teams or email as weaker evidence than a
  decision in force or the code.
- Keep it short. The user asks follow-ups in the same conversation.
- If the answer is durable and not yet in the KB, offer once: "Save this as a fact?" In the app there's
  a button for it, so don't offer there.

## 4. Missing a source?

If the question clearly needs a source that isn't configured (a documentation site, another wiki, a
tool), say which one and how to add it in a single line:
`kb sources add --kind url --title "…" --use-for "…" --config url=…` (or the app's Sources page).
When it's one specific page, artifact, mail or file the user can reach and you can't, say they can keep a copy
in **References** (the app's Add menu: web page or artifact, email, Teams chat, file).
