# ccmd — talk to CC in a markdown file

`ccmd` turns a markdown file into a conversation with CC. You write a prompt in
your editor, press cmd+enter, and the reply streams into the same file below what
you wrote. Thinking and tool activity go to a separate trace file, so the
conversation itself stays readable.

The point is not to replace the CC terminal UI. It is to make the conversation an
editable document — one you can revise before sending, fold, search, diff, and
keep.

> **Status: design phase.** The CLI currently reports its version and nothing
> else. The architecture is specified in
> [docs/designs](docs/designs/design.8_5_2026.ccmd_architecture.md) and lands
> incrementally.

## How it will work

```
┌─ conversation.md ───────────────┐
│ ---                             │
│ session_id: b6c23662-…          │
│ cwd: ~/workspace/fleetio        │
│ ---                             │
│                                 │
│ ## Me — 14:32                   │
│ Why is this spec flaky?         │   cmd+enter
│                                 │  ──────────▶  ccmd  ──▶  claude -p
│ ## CC — 14:33                   │                          (one long-lived
│ Because the factory…            │  ◀──────────             process)
│                                 │    streamed
│ ## Me — 14:41                   │
│ ▌                               │
└─────────────────────────────────┘
```

One long-lived `claude` process holds the session, so each turn costs no
re-reading of history. The session id lives in the file's frontmatter, so a
crashed process resumes exactly where it left off.

## Installation

Requires Ruby 3.4+ and the [Claude Code](https://claude.com/claude-code) CLI on
your PATH.

```bash
git clone https://github.com/omgreenfield/claude-code-md.git && cd claude-code-md && bin/setup
```

Then alias the executable:

```bash
alias ccmd='/path/to/claude-code-md/exe/ccmd'
```

Aliasing the checkout rather than `gem install`ing is deliberate: a gem-installed
executable lives in whichever Ruby installed it, and disappears when you switch
Ruby versions.

## Development

```bash
bundle exec rake
```

Runs RSpec and RuboCop. Both must pass before a commit.

## License

MIT.
