# Inline Responses

Design written 8/5/2026 for [feature.inline_responses.md](../features/feature.inline_responses.md).

Additive to [design.8_5_2026.ccmd_architecture.md](design.8_5_2026.ccmd_architecture.md), which is **not modified by this document**. Everything this feature changes about the base design is collected in [Changes To The Base Design](#changes-to-the-base-design).

- [Inline Responses](#inline-responses)
  - [TL;DR](#tldr)
  - [The Problem](#the-problem)
  - [Marker Vocabulary](#marker-vocabulary)
  - [A Round Trip](#a-round-trip)
  - [Detection](#detection)
    - [Block Snapshots](#block-snapshots)
    - [The State File](#the-state-file)
    - [Diff Rules](#diff-rules)
  - [Pairing Responses To Prompts](#pairing-responses-to-prompts)
  - [What Gets Sent](#what-gets-sent)
  - [Resolution Without Rewriting](#resolution-without-rewriting)
  - [Edits To Your Own Earlier Blocks](#edits-to-your-own-earlier-blocks)
  - [Teaching CC The Vocabulary](#teaching-cc-the-vocabulary)
  - [Changes To The Base Design](#changes-to-the-base-design)
  - [Configuration](#configuration)
  - [Edge Cases](#edge-cases)
  - [Testing](#testing)
  - [Deferred](#deferred)

## TL;DR

When CC asks questions or lists decisions, you answer them where they are — as a sub-bullet under each one — instead of restating them at the bottom of the file.

The mechanism: `ccmd` wrote every byte of every CC block, so it keeps a snapshot of each one. On send it re-reads the conversation, diffs each block against its snapshot, pairs your added lines to the marker lines above them, and sends those pairs alongside whatever you typed in the trailing block.

Three decisions worth knowing before reading further:

- **Marker vocabulary is borrowed wholesale** from the `code-comment-threads` skill, so `❓ ❗️ 💬 ✅ ❌` mean the same thing in a ccmd conversation as in a code review thread.
- **Nothing is rewritten.** Unlike `code-comment-threads`, ccmd never edits a line it already wrote — the append-only invariant from the base design is what makes it safe to write into a file you have open. Resolution is tracked in state and acknowledged in the next reply.
- **Answers are consumed exactly once.** Snapshots advance after a turn, so an answer is never re-sent.

## The Problem

The base design extracts your new text from one place: everything after the final `role=me` marker. That works for a linear conversation and fails the moment CC produces a list:

```markdown
## CC — 14:33

Three things before I can write this:

- ❓ Should `ls` scan both locations by default?
- ❓ Is `docs/agent-local/conversations` the right repo-relative default?
- ❗️ Confirm the poll interval before I bake it into the spec.
```

Answering those at the bottom of the file means retyping enough of each question to disambiguate — "yes to the first, no to the second, 200ms" — which is exactly the friction that makes people abandon the format and go back to the terminal.

## Marker Vocabulary

Identical to the `code-comment-threads` skill, so one set of symbols works in both places:

| Marker | Meaning | Written by |
| --- | --- | --- |
| `❓` | Question — an answer is needed | CC |
| `❗️` | Request — an action or confirmation is needed | CC or you |
| `💬` | Reply — commentary that settles nothing | either |
| `✅` | Approve — yes, proceed | you |
| `❌` | Reject — no, or do it differently | you |

A marker line in a conversation is a list item whose text begins with a marker, after any leading whitespace:

```markdown
- ❓ Should `ls` scan both locations by default?
```

Every marker is overridable by environment variable, matching the skill's approach. A response is *any* line you add beneath a marker line, whether or not it carries a marker of its own — `- ✅ Yes` and a plain indented sentence are both responses. Markers on your side are for your benefit and for CC's skimming, not a parsing requirement.

## A Round Trip

CC asks, and `ccmd` renders an options line under each question:

```markdown
## CC — 14:33

Three things before I can write this:

- ❓ Should `ls` scan both locations by default?
  - Options: ✅ approve · ❌ reject · 💬 reply
- ❓ Is `docs/agent-local/conversations` the right repo-relative default?
  - Options: ✅ approve · ❌ reject · 💬 reply
- ❗️ Confirm the poll interval before I bake it into the spec.
  - Options: ✅ approve · ❌ reject · 💬 reply
```

You answer in place and press cmd+enter:

```markdown
- ❓ Should `ls` scan both locations by default?
  - Options: ✅ approve · ❌ reject · 💬 reply
  - ✅ Yes
- ❓ Is `docs/agent-local/conversations` the right repo-relative default?
  - Options: ✅ approve · ❌ reject · 💬 reply
  - ❌ Use `docs/conversations`. I'll handle ignoring it myself.
- ❗️ Confirm the poll interval before I bake it into the spec.
  - Options: ✅ approve · ❌ reject · 💬 reply
  - 💬 200ms, and make it configurable.
```

CC's next block acknowledges what it consumed, then continues:

```markdown
## CC — 14:41

> Answering ❓×2 and ❗️×1 from turn 3.

Switching the repo-relative default to `docs/conversations` and the poll
interval to a configurable 200ms.
```

Options lines are written by `ccmd`, never by CC, and are stripped before anything is sent — the same split the skill makes between a message's `text` and its `options`. They are on by default and can be turned off.

## Detection

- [Block Snapshots](#block-snapshots)
- [The State File](#the-state-file)
- [Diff Rules](#diff-rules)

### Block Snapshots

`ccmd` authored every byte of every block, so it knows what the file looked like when it last touched it. That is the whole trick: a block whose current text differs from its snapshot has been annotated by you.

Snapshots are taken at turn end, when the file is quiescent. Anything you add while a turn is streaming is picked up on the following send, not the current one.

### The State File

`<basename>.state.json`, a sibling of the conversation and its trace:

```json
{
  "version": 1,
  "session_id": "b6c23662-e28f-4153-b3d3-20ca7b4b8e76",
  "blocks": [
    { "turn": 1, "role": "me", "sha256": "…", "text": "Why is this spec flaky?" },
    { "turn": 1, "role": "cc", "sha256": "…", "text": "Because the factory…" }
  ],
  "consumed": [
    { "turn": 1, "role": "cc", "line": 4, "sha256": "…" }
  ]
}
```

This is the one file `ccmd` rewrites wholesale rather than appending to, which is safe because you never have it open. Writes are atomic: write a temporary file in the same directory, then rename.

`consumed` records the marker lines whose answers have already been sent, keyed by content hash rather than line number so it survives you editing text above them.

Losing or deleting the state file is recoverable, not fatal: `ccmd` rebuilds snapshots from the current file contents and treats everything as already-consumed, so the next send behaves like a fresh conversation with history.

### Diff Rules

For each block, compare current text to snapshot:

- **Added lines** are responses. This is the case that matters.
- **Modified lines** inside a CC block are sent too, as a unified diff of that block, prefixed so CC understands you edited its words rather than answering. Silently dropping them would be worse — you meant something by the edit.
- **Deleted lines** are reported in the terminal and otherwise ignored. Deleting CC's text is housekeeping, not communication.
- **Whitespace-only changes** are ignored entirely.
- **Options lines** are stripped before diffing, so toggling `CCMD_SHOW_OPTIONS` never registers as an edit.

Comparison is line-based over the block's body, excluding its marker comment and heading.

## Pairing Responses To Prompts

For each added line, walk upward within the same block to find the nearest preceding marker line whose indentation is strictly less than the added line's. That marker is the prompt being answered.

- An added line indented under a marker line pairs with it.
- An added line at column zero, or one with no marker line above it, is a **block-level annotation** — attached to the block, not to any single question.
- Multiple added lines under the same marker are joined in document order into one response.
- A marker line you add yourself is a new prompt directed at CC, not an answer, and is sent as a block-level annotation.

Fenced code blocks are skipped whole, so a `❓` inside an example never becomes a thread. This mirrors the skill's markdown rules.

## What Gets Sent

One user message per send, assembled from up to two parts and containing only the parts that exist:

```
[inline responses]

turn 3 · ❓ Should `ls` scan both locations by default?
  ✅ Yes

turn 3 · ❓ Is `docs/agent-local/conversations` the right repo-relative default?
  ❌ Use `docs/conversations`. I'll handle ignoring it myself.

turn 3 · ❗️ Confirm the poll interval before I bake it into the spec.
  💬 200ms, and make it configurable.

[new message]

Also bump the send-gate poll to match.
```

The prompt text is quoted back so CC does not have to re-read the file to know what is being answered. Turn numbers let it reference specifics.

An empty trailing block is no longer "nothing to send" — inline responses alone constitute a turn.

The composed payload is recorded verbatim in the trace, so what was actually sent is always inspectable.

## Resolution Without Rewriting

`code-comment-threads` marks a thread resolved by rewriting the line in place. `ccmd` will not do that.

The base design's append-only invariant is what makes it safe to write into a file you have open in an editor: the OS places every write at the end, and edits you make above are never clobbered. Rewriting a resolved `❓` into a `✅` twenty lines up would break that for a cosmetic gain, and would fight your editor buffer while you are typing.

Instead:

- The state file's `consumed` list is the source of truth for what has been answered.
- The next CC block opens with an acknowledgment line naming what it consumed.
- An answer already in `consumed` is never re-sent, so re-saving the file is idempotent.

The document is therefore a faithful, append-only record: the question and your answer both stay exactly where you wrote them.

## Edits To Your Own Earlier Blocks

Treated identically to edits of CC blocks: diffed, paired, and sent as annotations tagged with their turn.

They cannot rewrite history — the session already holds the original turn — so they read as corrections. Sending them is still right, because "actually I meant `docs/conversations`" is a real message. The terminal notes that the edit was sent as a correction rather than a replacement, so the distinction is never a surprise.

## Teaching CC The Vocabulary

CC has to know the markers exist to use them. `ccmd` passes a fragment via `--append-system-prompt` at spawn:

> You are talking to the user inside a markdown file. When you need decisions, write each one as its own list item beginning with `❓` for a question or `❗️` for a request. The user answers beneath each item, so keep each item self-contained and answerable on its own. Do not write options lines; the harness adds them.

The fragment is rendered from resolved configuration, so overridden markers stay correct, and it is suppressed when inline responses are disabled.

## Changes To The Base Design

Collected here so the base design does not have to be edited to absorb this feature.

New components:

| Component | Responsibility |
| --- | --- |
| `Markers` | Resolve the five markers and the options label from env; render options lines |
| `BlockIndex` | Pure. Split a conversation into blocks by marker comment, exposing turn, role, and body |
| `ConversationState` | Load, update, and atomically write `<basename>.state.json` |
| `InlineResponses` | Pure. Diff blocks against snapshots, pair additions to marker lines, emit structured responses |
| `TurnComposer` | Pure. Merge inline responses and trailing-block text into one payload |

Modified components:

| Component | Change |
| --- | --- |
| `DeltaExtractor` | Narrows to "text after the last `role=me` marker" and becomes an input to `TurnComposer` rather than the whole story |
| `ConversationFile` | Gains options-line rendering after CC's marker lines, and updates `ConversationState` at turn end |
| `ClaudeProcess` | Adds `--append-system-prompt` with the vocabulary fragment |
| `TranscriptRenderer` | Records the composed payload and the consumed marker list in the trace |

Unchanged: the send gate, the two-thread model, append-only writes, session resume, conversation location, and every error-handling rule.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CCMD_INLINE_RESPONSES` | `true` | Master switch. Off restores pure trailing-block behavior |
| `CCMD_QUESTION_MARKER` | `❓` | |
| `CCMD_REQUEST_MARKER` | `❗️` | |
| `CCMD_REPLY_MARKER` | `💬` | |
| `CCMD_APPROVE_MARKER` | `✅` | |
| `CCMD_REJECT_MARKER` | `❌` | |
| `CCMD_SHOW_OPTIONS` | `true` | Render options lines under CC's marker lines |
| `CCMD_OPTIONS_LABEL` | `Options:` | Rejected at startup if it begins with a configured marker, since that would parse as a message |

Booleans accept `1/true/yes/on` and `0/false/no/off`, and ambiguous values are rejected rather than guessed — same contract as the skill.

## Edge Cases

| Situation | Behavior |
| --- | --- |
| Marker inside a fenced code block | Skipped. Fences are consumed whole |
| Response added while a turn streams | Picked up on the next send; snapshots only advance at turn end |
| Same answer saved twice | Sent once. `consumed` is keyed by content hash |
| Answer edited after being sent | The edit is a new addition and is sent as a follow-up |
| Marker comment deleted or corrupted | Hard failure with the line number. Guessing block boundaries would silently send the wrong text |
| Block reordered by hand | Detected as a delete plus an add; the add is sent, the delete is reported |
| `/send` token in the trailing block | Stripped before diffing, as today |
| State file missing | Rebuilt from current contents, everything marked consumed, no spurious resend |
| State file from a newer `version` | Refuse to run rather than misread it |
| Inline responses disabled mid-conversation | Snapshots keep updating, so re-enabling does not dump a backlog |

## Testing

`BlockIndex`, `InlineResponses`, `TurnComposer`, and `Markers` are pure, which is where the coverage concentrates. Fixtures are conversation files with known annotations, paired with the expected payload.

Cases that must have specs:

- One answer under one question
- Several answers under several questions in one block
- Answers spread across two non-adjacent blocks
- Block-level annotation with no marker above it
- A marker inside a fenced block, ignored
- An edit to CC's prose, sent as a diff
- A deletion, reported and not sent
- Idempotence: same file, two sends, second produces nothing
- Options lines stripped from both the diff and the payload
- State file missing, and state file from a future version

`ConversationState` is tested in a tmpdir, including a simulated crash between temporary write and rename.

## Deferred

- **In-place resolution markers**, flipping a consumed `❓` to `✅`. Wants a safe way to edit a file you have open; revisit only if reading old threads proves genuinely confusing.
- **Threading beyond one round.** Today an answer is consumed and the conversation moves on. Multi-round clarification under a single marker, with the skill's `awaiting clarification` state, is a larger feature.
- **Cross-file threads**, answering a ccmd question from inside a source file. Attractive, and squarely `code-comment-threads` territory rather than ccmd's.
