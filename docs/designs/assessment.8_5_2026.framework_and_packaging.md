# Framework And Packaging Assessment

Written 8/5/2026 while deciding where `ccmd` should live and what it should be built with. Migrated here from a scratch note in `agent-vault`. The architecture it feeds is
[design.8_5_2026.ccmd_architecture.md](design.8_5_2026.ccmd_architecture.md).

- [TL;DR](#tldr)
- [Decisions](#decisions)
- [Why Not A Shell Script](#why-not-a-shell-script)
- [Language](#language)
- [Why A Separate Repo](#why-a-separate-repo)
- [Thor: Rejected, Then Adopted](#thor-rejected-then-adopted)
- [Packaging And Distribution](#packaging-and-distribution)
- [Protocol Findings](#protocol-findings)

## TL;DR

Ruby, Thor, its own public repo, shipped as a gem named `claude-code-md` whose executable is `ccmd`.

The interesting part of the record is the Thor decision, which was made twice and reversed once when the premise changed. It was rejected while the tool was going to live inside `agent-vault`, and adopted once it got its own repo — because three of the four reasons against it were really reasons against adding Bundler to a dependency-free vault.

## Decisions

| Decision | Choice |
| --- | --- |
| Home | Its own public repo, `omgreenfield/claude-code-md` |
| Language | Ruby |
| CLI framework | Thor, plus `omg-thor-ext` |
| Gem name | `claude-code-md` |
| Executable | `ccmd` |
| Ruby namespace | `ClaudeCodeMd`, flattened rather than `Claude::Code::Md` |
| Scaffold | `bundle gem`, with conventions grafted from `ruby-cli-template` |
| Daily install | Alias the checkout's `exe/ccmd`, not `gem install` |
| In-file approvals | Deferred out of v1 |

## Why Not A Shell Script

The program is a streaming JSON state machine, not command glue. It has to JSON-encode arbitrary markdown prose onto a single line, read a child's stdout concurrently with watching the filesystem, correlate control requests with responses, and parse YAML. In bash, the first needs `jq` regardless, the second needs coprocesses and has no real threads, the third has nowhere clean to live, and the fourth has no answer at all.

## Language

**Ruby** was chosen. The standard library covers every part — `open3`, `json`, `yaml`, `Thread`, `Queue`, `Signal`, and append-mode `File` — and it is the language its author can debug at 11pm without relearning anything.

**Python** was the real contender, purely because the official `claude-agent-sdk` already implements the permission callback, interrupt, and hook plumbing that Ruby has to hand-roll. That advantage only matters if in-file approvals are in scope. They are not in v1, so it did not outweigh writing in the more comfortable language.

**TypeScript** has the reference SDK and the best protocol support, but no other reason to be here.

The protocol layer is deliberately one isolated component, so adopting the Python SDK later would be a swap rather than a rewrite.

## Why A Separate Repo

The alternative was `agent-vault`, which is a distribution repo: its job is shipping skills, plugins, prompts, and hooks into `~/.claude`. `ccmd` is none of those, and the vault's installer would not install it — it would have sat there wired up by an alias, participating in nothing.

Size settled it. Seven or eight collaborating files, a test suite over recorded fixtures, and a protocol layer that will break when the CC CLI changes is a project with its own release cadence and its own issues. Separating it also keeps vault commits about vault things.

## Thor: Rejected, Then Adopted

### The Case Against, While It Lived In The Vault

1. **Leverage mismatch.** Thor is a dispatcher. Roughly 95% of this program sits below the dispatch layer, in process supervision and stream handling, where Thor has no opinion. Against `OptionParser` plus a `case`, it saves perhaps 60–80 lines out of ~600.
2. **Gem bloat in a dependency-free repo.** The vault's Ruby precedent is stdlib-only scripts with minitest and no Gemfile.
3. **Bootstrap fragility.** A Gemfile would make `bundle install` a precondition before the editor loop worked at all, in a repo that otherwise runs from a bare clone.
4. **Repo shape mismatch.** `ruby-cli-template` is a `gh repo create --template` artifact, assuming its own root.

### Why It Reversed

Reasons 2, 3, and 4 were all premised on living inside `agent-vault`. Give the tool its own repo and they evaporate. Only the leverage argument survives, and that argument was always that Thor's *benefit* is small — never that its cost is high. In a repo already running Bundler with `bin/setup` and CI, Thor's marginal cost is near zero, and `omg-thor-ext` buys consistent CLI behavior for free. Small benefit at near-zero cost wins.

### Arguments Deliberately Not Used

Recorded so the decision is not re-litigated on them:

- **Boot time.** Irrelevant. The process is long-lived and launched once per conversation, so Bundler and autoload cost vanish. It would matter for a tool run dozens of times an hour.
- **Thor's CLI misbehavior** around exit codes, unknown flags, and help-on-no-args. Already fixed by `omg-thor-ext`.
- **"It's already installed"** and **"other projects use it."** Not reasons in either direction.

## Packaging And Distribution

`spec.executables` decouples the command from the gem, so `claude-code-md` ships `ccmd`. Thor is simply a runtime dependency; Bundler and Rails ship Thor CLIs the same way. `omg-thor-ext` is published, MIT, and MFA-required, so depending on it is safe for other people.

`ruby-cli-template` was not used as the starting point, because its layout is app-shaped in four ways that fight gem packaging: no gemspec, `config/app.rb` doing `require "bundler/setup"` and `Bundler.require`, Zeitwerk pointed at `src/` in the checkout, and a logger writing `log/` relative to the current directory. `bundle gem` produces correct plumbing instead, and the template's RuboCop config, CI workflow, `bin/console`, and Thor wiring were grafted on.

Bundler expanded the dashed gem name into a `Claude::Code::Md` namespace. That was flattened to `ClaudeCodeMd`: a third-party gem should not define a top-level `Claude` module, both because it invites a collision with a future official gem and because it implies an affiliation that does not exist. The gem is CLI-first, so nothing depends on `require "claude-code-md"` resolving.

Distribution, in the order it will probably happen:

1. **Alias the checkout's `exe/ccmd`.** What the author actually uses. A `gem install`ed executable lives in whichever Ruby installed it and vanishes on a version switch — a bad property for a tool you run all day.
2. **`gem build` and local `gem install`** to exercise real packaging without publishing.
3. **`rake release` to RubyGems** if and when other people should have it. Check name availability first.
4. **Homebrew tap** if the install story ever needs to be nicer. More machinery than the problem currently justifies.

## Protocol Findings

From three probes against `claude` 2.1.212 and a read of the binary's strings:

- Streaming input works. One JSON line on stdin yields `stream_event` text deltas and then a `result` line carrying `session_id`, `duration_ms`, `is_error`, and `permission_denials`.
- `--verbose` is mandatory with `--output-format stream-json`.
- A child CC resolves "the current directory" to its own scratchpad. cwd must be set explicitly by the parent.
- The binary contains `initialize`, `can_use_tool`, `hook_callback`, `interrupt`, and `set_permission_mode` control subtypes. A client that declares `can_use_tool` during `initialize` receives permission decisions and answers with a `control_response`. An earlier conclusion in the same session — that print mode could not ask for permission answerably — was wrong; the probe that produced it simply never declared the capability.
- The field shapes of those control messages are **not** verified and are undocumented. That is the risk hand-rolling the protocol accepts, and the reason in-file approvals are deferred.
