---
name: write-as-me
description: Write an email, a chat message (Teams, Slack) or another text in the user's own style, learned from what they actually sent to the same person, group or kind of receiver, read from the user's own mail and chat tools. Asks who it is for first. Use for "write as me", "write this in my style", "draft an email to …", "write a Teams message to …", "answer this for me", "how would I say this to …".
allowed-tools: Bash(kb:*), Read, Grep, Glob, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__read_resource, mcp__claude_ai_Microsoft_365__chat_message_search, mcp__claude_ai_Microsoft_365__teams_list_chats, mcp__claude_ai_Microsoft_365__teams_list_channel_messages, mcp__claude_ai_Microsoft_365__search_people
---

# Write as me

Write what the user asks for so it reads as if they wrote it to *that* receiver: their language, greeting,
sign-off, length, tone, how direct they are, their habits. The style comes from what they really sent, and it
differs by receiver and channel, so **know who it is for before you choose the style**.

## 1. Who and where

From the request, settle three things. Ask for whatever is missing in **one** question with a choices block,
before reading any references:

- **Channel:** an email, a chat message (one person, a group chat or a channel), or something else (a post, a
  document, a comment on a pull request).
- **Receiver:** a person, several people, a group chat or a channel, or a kind of receiver ("a customer",
  "the whole team", "my manager"). Offer the likely ones as options: people and chats named in the request or in
  the thread being answered, `kb people search "<name>"`, and the recent chats in the user's chat tool.
- **Work or personal:** usually clear from the receiver; ask only when it isn't.

## 2. Find how the user writes to them

`kb tools` names the user's mail and chat tools. Read only those, never another tool that happens to be connected.
When the channel's tool isn't set or isn't connected, say so in one line and ask for a sample of their writing
instead.

Look for what **the user sent**, best matches first, and stop at about 5–8 good examples:

1. To the same receiver in the same channel (the same person's mail, the same group chat or channel).
2. To the same receiver in another channel, or to people like them (the same team, the same customer, the same
   language) in the same channel.
3. The user's recent sent mail or chat messages in general, to fill gaps (greeting, sign-off, language).

Where to look:
- **Microsoft 365 mail:** `outlook_email_search` in the `sentitems` folder, by the receiver's name or address
  (`search_people` finds an address from a name), newest first; read a message with `read_resource` when the
  preview is too short.
- **Gmail:** search `in:sent to:<address or name>`, then `in:sent`.
- **Teams:** `teams_list_chats` to find the chat or group, then `chat_message_search` for messages from the user
  in it, or in channels the receiver is in.
- **Slack:** search `from:me in:<channel or person>`.

Use only the user's own text, not quoted replies, forwarded mail or signatures from others. Skip automated mail,
calendar replies and one-word messages.

## 3. Write it

Work out the style from the examples, without saying all of it back: the language (match what the user used
with this receiver, even when the request is in another language), greeting and sign-off (the exact words they
use, or none), length and paragraphing, formality and tone, how they ask for things, emoji, bullet lists,
signature (in mail, only when they add one themselves).

Then write the text. Keep to what the user asked to say: don't add facts, promises, dates or apologies they
didn't give; ask when something needed is missing. When it answers a thread, read the thread first so it
answers what was asked.

Reply with:
- the text, ready to copy (for an email, the subject line first);
- one short line on whose style it follows ("in the style of your Teams messages to the Platform group, in Danish");
- a choices block: `Looks right (Recommended)`, `Shorter`, `More formal`, `Less formal`, and, for an email in a
  tool that can make drafts (Microsoft 365: `outlook_create_draft`), `Save it as a draft`.

## Rules

- Never send anything. A draft is saved only when the user picks it.
- The examples are the user's private mail and chats: use them to learn the style, don't quote them back beyond a
  few words, and never save them in the knowledge base.
- Don't name KB ids or local paths in the text.
- When there are no examples for this receiver, say so in the line about the style and use the closest ones.
