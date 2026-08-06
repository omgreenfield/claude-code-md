# `ccmd` Architecture

Design written 8/5/2026. Companion to
[assessment.8_5_2026.framework_and_packaging.md](assessment.8_5_2026.framework_and_packaging.md),
which records why the stack is what it is.

- [`ccmd` Architecture](#ccmd-architecture)
  - [TL;DR](#tldr)
  - [Goals And Non-Goals](#goals-and-non-goals)
  - [The Loop](#the-loop)
  - [File Formats](#file-formats)
    - [Conversation File](#conversation-file)
    - [Trace File](#trace-file)
    - [Send Sidecar](#send-sidecar)
  - [Conversation Location](#conversation-location)
  - [CC Invocation](#cc-invocation)
  - [Components](#components)
  - [One Turn, End To End](#one-turn-end-to-end)
  - [Concurrency And File Safety](#concurrency-and-file-safety)
  - [Error Handling](#error-handling)
  - [CLI Surface](#cli-surface)
  - [Testing Strategy](#testing-strategy)
  - [Deferred](#deferred)
  - [Resolved Questions](#resolved-questions)

## TL;DR

You write prompts in a markdown file. `ccmd` watches for a deliberate send signal, hands your new text to a long-lived `claude` process, and streams the reply back into the same file below what you wrote. Thinking and tool activity go to a sibling trace file.

Five load-bearing choices:

- **One long-lived process**, fed through `--input-format stream-json`, so a turn costs no re-reading of history and the prompt cache stays warm.
- **`ccmd` generates the session UUID up front** and passes `--session-id`, so the id can be written into frontmatter at file creation and the markdown never needs rewriting afterward.
- **Send is gated on deliberate intent** — a `.send` sidecar from a cmd+enter keybinding, or a trailing `/send` line — never on file save, because saving is habitual.
- **Every write to the conversation file is append-only**, so edits you make higher up while CC is working are never clobbered.
- **Two sinks.** Prose to the conversation, everything else to the trace.

## Goals And Non-Goals

Goals:

- Compose and revise a prompt with full editor affordances before sending it.
- Keep the whole conversation as one editable, foldable, searchable, diffable document.
- Never leave the editor for a turn: no tab closing, no terminal switching.
- Survive a crashed or killed `claude` process without losing the thread.

Non-goals:

- Replacing the CC terminal UI. Interactive-only features stay there.
- Multiplexing many conversations in one process. v1 is one process per conversation file.
- Rendering an approval prompt into the markdown. See [Deferred](#deferred).

## The Loop

1. `ccmd path/to/conversation.md` creates or attaches to a conversation and starts watching.
2. You type under the trailing `## Me` heading, saving as often as you like. Nothing happens.
3. cmd+enter saves and touches `conversation.md.send`.
4. `ccmd` extracts the text you added, deletes the sidecar, and writes one JSON line to the child's stdin.
5. The reply streams in under a new `## CC` heading. Thinking and tool calls go to `conversation.trace.md`.
6. When the turn ends, `ccmd` appends a fresh `## Me` heading and returns to watching.

Editor wiring, which is one-time and what `ccmd setup` writes:

```jsonc
// keybindings.json — an entry in the top-level array
{
  "key": "cmd+enter",
  "when": "editorTextFocus && resourceExtname == .md",
  "command": "runCommands",
  "args": { "commands": [
    "workbench.action.files.save",
    { "command": "workbench.action.tasks.runTask", "args": "cc-send" }
  ]}
},
```

```jsonc
// tasks.json — the "cc-send" task
{
  "label": "cc-send",
  "type": "shell",
  "command": "touch '${file}.send'",
  "presentation": { "reveal": "never" },
  "problemMatcher": []
}
```

`runCommands` is built into VSCode, so no extension is needed.

## File Formats

- [Conversation File](#conversation-file)
- [Trace File](#trace-file)
- [Send Sidecar](#send-sidecar)

### Conversation File

```markdown
---
session_id: b6c23662-e28f-4153-b3d3-20ca7b4b8e76
cwd: /Users/matthew.greenfield/workspace/fleetio/fleetio
model: opus
permission_mode: auto
created: 8/5/2026 14:32
---

<!-- ccmd:turn=1 role=me -->
## Me — 14:32

Why is this spec flaky?

<!-- ccmd:turn=1 role=cc -->
## CC — 14:33

Because the factory reuses a memoized record across examples.

[trace](conversation.trace.md#turn-1)

<!-- ccmd:turn=2 role=me -->
## Me — 14:41

```

The HTML comment markers are what the parser reads; the headings are for you. Comments are invisible when rendered and cannot be produced accidentally by ordinary prose, which the headings alone could be.

Frontmatter is written once, at file creation. Because `ccmd` generates the session UUID itself and passes it via `--session-id`, nothing in the frontmatter ever needs updating, so the file is only ever appended to.

Delta extraction rule: find the last `role=me` marker, take everything after its heading line, strip a trailing `/send` line and surrounding whitespace. Only that text is sent — the session already holds the history.

### Trace File

`<basename>.trace.md`, one section per turn, anchored so the conversation can link into it:

```markdown
## Turn 1 — 14:33

<details><summary>Thinking</summary>

…thinking text…

</details>

### `Read(spec/models/foo_spec.rb)`

<details><summary>Result — 412 lines</summary>

```
…full tool result…
```

</details>

Duration 13.1s · 2 turns · $0.041
```

Tool results are recorded **in full**, not truncated. Writing them costs no tokens: the trace is built from data CC already streamed over stdout, those results already entered the model's context when the tool ran, and nothing in this design ever feeds the trace back into a session. Token cost is set by what goes into an API request, and a local file never goes into one.

The only cost is trace size, so each result is wrapped in a collapsed `<details>` block and `--trace-max-bytes` can cap an individual result for sanity. It defaults to unlimited.

### Send Sidecar

`<file>.send`. Contents are ignored; existence is the signal. Deleted the moment it is seen, before the turn starts, so a second cmd+enter during a turn queues rather than double-firing.

## Conversation Location

Where a conversation file lives is configurable, with two shapes: repo-relative or global.

Resolution order, first match wins:

| Source | Meaning |
| --- | --- |
| A path argument containing `/` or ending in `.md` | Used verbatim. No resolution happens |
| `--dir PATH` | Explicit directory for this invocation |
| `--repo` / `--global` | Force a shape, using the defaults below |
| `CCMD_LOCATION` | `repo` or `global` |
| Inside a git repo | Repo-relative |
| Otherwise | Global |

Defaults, both overridable by environment variable:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CCMD_REPO_SUBDIR` | `docs/agent-local/conversations` | Appended to the git repo root |
| `CCMD_GLOBAL_DIR` | `$HOME/trunk/docs/conversations` | Used outside a repo, or with `--global` |

A bare argument with no slash and no extension is a slug, resolved inside the directory above: `ccmd flaky-spec` becomes `<dir>/conversation.8_5_2026.flaky_spec.md`.

The repo-relative default sits under `docs/agent-local`, which the global gitignore already excludes. Conversations inside a work repo therefore never show up in `git status`, without ccmd writing to `.git/info/exclude` or the repo's `.gitignore`. Pointing `CCMD_REPO_SUBDIR` somewhere tracked is allowed, and then keeping them out of commits is your business.

`ccmd ls` scans the resolved directory. `ccmd ls --all` scans both the repo-relative and global directories.

## CC Invocation

Verified against `claude` 2.1.212:

```bash
claude -p --verbose \
  --input-format stream-json \
  --output-format stream-json \
  --include-partial-messages \
  --session-id <uuid> \
  --model <model> \
  --permission-mode <mode>
```

`--verbose` is mandatory with `--output-format stream-json`; without it the CLI exits 1. The child is spawned with its working directory set to the frontmatter `cwd` — a child CC left to its own devices resolves relative paths against its own scratchpad, not the caller's directory.

Resuming a session that outlived its process swaps `--session-id` for `--resume <uuid>`.

Each user turn is one line on stdin:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]},"parent_tool_use_id":null,"session_id":"<uuid>"}
```

Events consumed from stdout: `system` (`init`, `thinking_tokens`, `post_turn_summary`, `hook_started`, `hook_response`), `stream_event` (`content_block_delta` carrying `delta.text` or thinking deltas), `assistant` (tool_use blocks), `user` (tool_result blocks), `rate_limit_event`, and `result` (carrying `session_id`, `duration_ms`, `is_error`, `permission_denials`).

## Components

Each is a file under [lib/claude_code_md](../../lib/claude_code_md), one clear job, testable alone.

| Component | Responsibility | Depends on |
| --- | --- | --- |
| `ConversationFile` | Create with frontmatter, read frontmatter, append prose, open and close turn markers | filesystem |
| `SendGate` | Detect sidecar or `/send`; return `:sidecar`, `:token`, or `nil`; delete the sidecar | filesystem |
| `DeltaExtractor` | Pure. Markdown in, your new text out | nothing |
| `EventCodec` | Pure. Encode a user turn to one JSON line; decode a stdout line into an event value | nothing |
| `ClaudeProcess` | Spawn with cwd and flags, write turns to stdin, yield decoded events, interrupt, respawn on death | `EventCodec` |
| `TranscriptRenderer` | Route events to the two sinks and format them | `ConversationFile` |
| `TurnState` | idle → streaming → tool-wait → done; queue turns arriving mid-flight | nothing |

`DeltaExtractor`, `EventCodec`, and `TranscriptRenderer` are pure or nearly so, which is where the test value concentrates.

## One Turn, End To End

1. `SendGate#poll` returns `:sidecar`; the sidecar is deleted.
2. `DeltaExtractor` reads the file and returns your new text. Empty means ignore and keep watching.
3. `TurnState` moves idle → streaming. If it was already streaming, the text is queued and nothing else happens.
4. `ConversationFile` appends the `role=cc` marker and heading.
5. `EventCodec.encode_user` produces the JSON line; `ClaudeProcess` writes it and flushes.
6. Text deltas append to the conversation as they arrive. Thinking deltas and tool events accumulate into the trace section.
7. The `result` event closes the turn: trace footer written, `[trace](…)` link appended, next `role=me` marker and heading appended, state back to idle.
8. If a turn was queued in step 3, it is sent now.

## Concurrency And File Safety

Two threads:

- **Reader thread** — blocking `readline` on the child's stdout, decodes, pushes onto a `Queue`.
- **Main thread** — interleaves `SendGate#poll` with draining that queue.

All file writes happen on the main thread. That is the point of the split: nothing writes the conversation concurrently.

Every conversation write uses append mode, so the OS places it at the current end of file regardless of what you changed above it. VSCode reloads a clean buffer automatically, so the reply appears as it streams. If you have unsaved edits when a write lands, VSCode reports the usual external-change conflict — the design accepts that rather than trying to merge, since the alternative is rewriting a file you are actively editing.

`SIGINT` sends an `interrupt` control request to the child rather than killing it, and appends `> ⏹ interrupted` to the conversation. A second `SIGINT` within two seconds exits.

## Error Handling

| Condition | Behavior |
| --- | --- |
| Child exits mid-turn | Append a warning blockquote, respawn with `--resume`, re-send the pending text once |
| `result.is_error` | Append the error as a blockquote; keep the session |
| `result.subtype` is a refusal or limit | Append verbatim so the reason is visible in the document |
| Unparseable stdout line | Record it in the trace, continue |
| Session id in frontmatter unknown to CC | Start a fresh session, note the substitution in the conversation |
| Conversation file deleted while running | Stop with a clear error rather than recreating it |
| `claude` not on PATH | Fail at startup with an actionable message |

Rate limit events are recorded in the trace, and surfaced in the conversation only when they actually block a turn.

## CLI Surface

| Command | Behavior |
| --- | --- |
| `ccmd <file>` | Create or attach, then watch. The default and dominant path |
| `ccmd setup` | Write the cmd+enter keybinding and the `cc-send` task |
| `ccmd ls` | List conversations with session id and last activity; `--all` scans both locations |
| `ccmd trace <file>` | Open the trace beside the conversation |

Flags on the default command: `--cwd`, `--model`, `--permission-mode`, `--effort`, `--new`, `--dir`, `--repo`, `--global`, `--trace-max-bytes`.

Frontmatter wins over flags for an existing file, so reattaching cannot silently change a conversation's model or working directory. Location flags are the exception — they resolve *which* file to open, so they are read before any frontmatter exists.

## Testing Strategy

- Pure components get unit specs over recorded `.jsonl` fixtures in `spec/fixtures/`, captured from real sessions.
- `ClaudeProcess` is tested against a fake `claude` executable that replays a fixture line by line. No spec spawns real CC, so the suite costs nothing and runs offline.
- `SendGate` and `ConversationFile` are tested in a tmpdir, including the case where the file grows underneath an in-flight turn.
- `bundle exec rake` runs RSpec and RuboCop; both must pass before a commit.

## Deferred

- **In-file approvals.** The CLI binary contains `initialize`, `can_use_tool`, `hook_callback`, `interrupt`, and `set_permission_mode` control subtypes, so a client that declares `can_use_tool` during `initialize` can render a permission request into the markdown and read `y`/`n` back. Deferred because the field shapes are undocumented and v1 runs fine on `--permission-mode auto`.
- **One daemon, many conversations.** Currently one process per file. A daemon would cut memory and allow cross-conversation commands.
- **`ccmd fork`** to branch a conversation from a chosen turn, using `--fork-session`.
- **`ccmd export`** to strip markers and produce a clean document.

## Resolved Questions

1. **Verb list.** Approved as specified: default, `setup`, `ls`, `trace`.
2. **Where conversations live.** Configurable, repo-relative or global, specified in [Conversation Location](#conversation-location).
3. **Trace verbosity.** Full tool results. Writing them costs no tokens, since the trace is assembled from output CC already streamed and is never read back into a session. Size is managed by collapsing each result and by an opt-in `--trace-max-bytes` cap. See [Trace File](#trace-file).
