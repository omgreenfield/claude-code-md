# ccmd v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ccmd` so a markdown file becomes a working conversation with CC — you type, press cmd+enter, and the reply streams into the same file — including answering CC's questions in place beneath them rather than restating them at the bottom.

**Architecture:** A long-lived `claude -p` child is fed one JSON line per turn over stdin. A reader thread decodes its stdout onto a queue; the main thread interleaves draining that queue with polling for a send signal. Prose appends to the conversation file, everything else to a sibling trace. Because ccmd authored every byte of every block, it keeps snapshots in a sibling state file and diffs them on send, which is how answers written under a question get found and paired to it.

**Tech Stack:** Ruby 3.4+, Thor, `omg-thor-ext`, RSpec, RuboCop. Everything else is standard library.

**Specs this implements:** [design.8_5_2026.ccmd_architecture.md](../designs/design.8_5_2026.ccmd_architecture.md) and [design.8_5_2026.inline_responses.md](../designs/design.8_5_2026.inline_responses.md).

## Global Constraints

- Ruby `>= 3.4.0`; RuboCop `TargetRubyVersion: 3.4`.
- Runtime dependencies are exactly `thor ~> 1.5` and `omg-thor-ext ~> 0.1`. Everything else must be standard library. Do not add a gem without changing this line.
- `bundle exec rake` (RSpec + RuboCop) must pass before every commit.
- Strings are double-quoted; every file starts with `# frozen_string_literal: true`.
- Every write to a conversation file uses append mode. Never rewrite a conversation file after creation. The state file is the sole exception and is rewritten atomically.
- No spec may spawn the real `claude` binary. Subprocess behavior is tested against the fake executable built in Task 15.
- In prose and docs, write `CC`, not "Claude Code".
- Document classes and public methods. Omit docs where they add nothing. Put a blank commented line between a method description and any `@param`. Omit `@return [void]`.
- Namespace is `ClaudeCodeMd`. Files live in `lib/claude_code_md/`, specs mirror them in `spec/`.
- Every new file must be added to the `require_relative` list in `lib/claude_code_md.rb` in the task that creates it.

## Task Index

Pure components come first so the impure ones have something correct to build on.

| # | Task | Kind |
| --- | --- | --- |
| 1 | Record protocol fixtures | fixtures |
| 2 | Frontmatter and turn markers | pure |
| 3 | Marker vocabulary and configuration | pure |
| 4 | Trailing-block delta extraction | pure |
| 5 | Block index | pure |
| 6 | Inline response detection | pure |
| 7 | Turn composer | pure |
| 8 | Event codec | pure |
| 9 | Conversation state | file I/O |
| 10 | Conversation file | file I/O |
| 11 | Trace file | file I/O |
| 12 | Send gate | file I/O |
| 13 | Location resolution | file I/O |
| 14 | Conversation index | file I/O |
| 15 | Claude process | subprocess |
| 16 | Transcript renderer and prose stream | wiring |
| 17 | Turn state | pure |
| 18 | Session orchestrator | wiring |
| 19 | The `open` command | CLI |
| 20 | The `ls`, `trace`, and `setup` commands | CLI |

## Divergences From The Designs

Recorded up front so no task silently contradicts a spec. Each has a step that corrects the design text.

1. **`ConversationFile` does not own options-line rendering.** Inserting an options line after a marker line requires buffering streamed deltas until a line completes, which is stream concern, not file concern. `ProseStream` (Task 16) owns it.
2. **`ConversationFile` does not update `ConversationState`.** `Session` already owns turn boundaries, so it advances snapshots (Task 18).
3. **`TurnState` collapses `tool-wait`.** Nothing behaves differently during a tool call, so a fourth state would carry no information (Task 17).
4. **`ccmd setup` prints by default.** VSCode config is JSONC and comments cannot survive a JSON round trip, so writing is opt-in and refuses files it cannot rewrite faithfully (Task 20).
5. **`ClaudeProcess#interrupt` is not implemented.** The control-protocol field shapes are unverified, so Ctrl+C stops the child and the next turn resumes (Task 15).
6. **`consumed` is keyed by marker hash *and* response hash**, not marker hash alone. Marker-only keying would make "same answer saved twice → sent once" work but break "answer edited after being sent → sent as a follow-up". Both edge cases are in the inline-responses spec, and only the pair satisfies both (Task 9).

---

### Task 1: Record protocol fixtures

Every later task's tests depend on real CC output rather than a guess at its shape. Capture it once, commit it, and never call the network in a spec again.

**Files:**
- Create: `spec/fixtures/README.md`, `spec/fixtures/text_only.jsonl`, `spec/fixtures/with_tools.jsonl`, `spec/fixtures/with_thinking.jsonl`

**Interfaces:**
- Consumes: nothing.
- Produces: three JSONL fixtures, each one complete turn of `claude` stdout ending in a `result` line.

- [ ] **Step 1: Capture a text-only turn**

```bash
cd spec/fixtures
SID=$(uuidgen | tr 'A-Z' 'a-z')
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Reply with exactly: hello there friend\"}]},\"parent_tool_use_id\":null,\"session_id\":\"$SID\"}" \
  | claude -p --verbose --input-format stream-json --output-format stream-json \
      --include-partial-messages --session-id "$SID" --tools "" --model sonnet \
  > text_only.jsonl
```

- [ ] **Step 2: Capture a turn that uses tools**

```bash
cd spec/fixtures
SID=$(uuidgen | tr 'A-Z' 'a-z')
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Run the bash command: echo hi-from-fixture   Then tell me its output.\"}]},\"parent_tool_use_id\":null,\"session_id\":\"$SID\"}" \
  | claude -p --verbose --input-format stream-json --output-format stream-json \
      --include-partial-messages --session-id "$SID" --tools Bash --model sonnet \
  > with_tools.jsonl
```

- [ ] **Step 3: Capture a turn that thinks**

```bash
cd spec/fixtures
SID=$(uuidgen | tr 'A-Z' 'a-z')
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Think carefully step by step, then answer: what is 17 * 23?\"}]},\"parent_tool_use_id\":null,\"session_id\":\"$SID\"}" \
  | claude -p --verbose --input-format stream-json --output-format stream-json \
      --include-partial-messages --session-id "$SID" --tools "" --effort high --model sonnet \
  > with_thinking.jsonl
```

- [ ] **Step 4: Verify each fixture and note the delta shapes**

```bash
cd spec/fixtures
for f in *.jsonl; do
  echo "== $f"
  jq -r 'select(.type=="result") | "result: \(.subtype) is_error=\(.is_error)"' "$f"
  jq -r 'select(.type=="stream_event") | .event.delta.type' "$f" | sort -u
done
```

Expected: each file prints exactly one `result:` line, plus the delta types later tasks must handle. **If `with_thinking.jsonl` shows no thinking delta type, record that in the fixtures README and skip the thinking assertions in Task 16 rather than inventing a shape.**

- [ ] **Step 5: Document the fixtures**

Write `spec/fixtures/README.md` naming each file, the command that produced it, the output of `claude --version`, and the delta types seen in Step 4.

- [ ] **Step 6: Commit**

```bash
git add spec/fixtures
git commit -m "test: record CC stream-json fixtures"
```

---

### Task 2: Frontmatter and turn markers

**Files:**
- Create: `lib/claude_code_md/frontmatter.rb`, `lib/claude_code_md/turn_marker.rb`
- Create: `spec/frontmatter_spec.rb`, `spec/turn_marker_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Frontmatter.parse(String) -> Hash` with symbol keys, `{}` when absent.
  - `Frontmatter.render(Hash) -> String` including both `---` delimiters and a trailing blank line.
  - `TurnMarker.render(turn:, role:, time:) -> String` — comment line, heading line, blank line.
  - `TurnMarker.scan(String) -> Array<[line_index, turn_number, role_symbol]>`.
  - `TurnMarker.last_turn_number(String) -> Integer`, `0` when there are no markers.
  - `TurnMarker::PATTERN`, `TurnMarker::HEADING_PATTERN`.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/frontmatter_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::Frontmatter do
  it "returns an empty hash when there is no frontmatter" do
    expect(described_class.parse("## Me — 14:32\n\nhi\n")).to eq({})
  end

  it "parses symbol-keyed values" do
    text = "---\nsession_id: abc-123\nmodel: opus\n---\n\n## Me — 14:32\n"

    expect(described_class.parse(text)).to eq(session_id: "abc-123", model: "opus")
  end

  it "round-trips through render" do
    values = { session_id: "abc-123", cwd: "/tmp/repo" }

    expect(described_class.parse(described_class.render(values))).to eq(values)
  end

  it "ends the rendered block with a blank line" do
    expect(described_class.render(model: "opus")).to end_with("---\n\n")
  end
end
```

```ruby
# spec/turn_marker_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::TurnMarker do
  let(:time) { Time.new(2026, 8, 5, 14, 32, 0) }

  it "renders a comment, a heading, and a blank line" do
    expect(described_class.render(turn: 2, role: :me, time: time))
      .to eq("<!-- ccmd:turn=2 role=me -->\n## Me — 14:32\n\n")
  end

  it "labels the assistant role CC" do
    expect(described_class.render(turn: 2, role: :cc, time: time)).to include("## CC — 14:32")
  end

  it "scans markers with their line index" do
    text = "<!-- ccmd:turn=1 role=me -->\n## Me — 14:32\n\nhi\n<!-- ccmd:turn=1 role=cc -->\n"

    expect(described_class.scan(text)).to eq([[0, 1, :me], [4, 1, :cc]])
  end

  it "ignores a marker that is not alone on its line" do
    expect(described_class.scan("text <!-- ccmd:turn=1 role=me -->\n")).to be_empty
  end

  it "recognises the visible heading it writes" do
    expect("## CC — 14:33").to match(described_class::HEADING_PATTERN)
    expect("## Something else").not_to match(described_class::HEADING_PATTERN)
  end

  it "reports zero when no markers exist" do
    expect(described_class.last_turn_number("nothing here\n")).to eq(0)
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/frontmatter_spec.rb spec/turn_marker_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::Frontmatter`.

- [ ] **Step 3: Implement both modules**

```ruby
# lib/claude_code_md/frontmatter.rb
# frozen_string_literal: true

require "yaml"

module ClaudeCodeMd
  # The YAML block at the top of a conversation file. Parsing is tolerant: a
  # file without frontmatter yields an empty hash rather than raising.
  module Frontmatter
    DELIMITER = "---"

    # @param text [String] full conversation file contents
    def self.parse(text)
      return {} unless text.start_with?("#{DELIMITER}\n")

      closing = text.index("\n#{DELIMITER}\n", DELIMITER.length)
      return {} unless closing

      body = text[(DELIMITER.length + 1)...closing]
      (YAML.safe_load(body) || {}).transform_keys(&:to_sym)
    end

    # Renders a complete block, delimiters and trailing blank line included, so
    # callers can write it as the first bytes of a new file.
    def self.render(values)
      body = values.transform_keys(&:to_s).to_yaml.delete_prefix("#{DELIMITER}\n")
      "#{DELIMITER}\n#{body}#{DELIMITER}\n\n"
    end
  end
end
```

```ruby
# lib/claude_code_md/turn_marker.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # Delimits a turn with an HTML comment the parser reads plus a heading the
  # reader sees. Ordinary prose cannot produce the comment by accident, which is
  # why parsing never relies on the heading.
  module TurnMarker
    PATTERN = /\A<!-- ccmd:turn=(\d+) role=(me|cc) -->\z/
    HEADING_PATTERN = /\A## (?:Me|CC) — \d{2}:\d{2}\z/
    ROLE_HEADINGS = { me: "Me", cc: "CC" }.freeze

    # @param role [Symbol] :me or :cc
    def self.render(turn:, role:, time:)
      <<~MARKER
        <!-- ccmd:turn=#{turn} role=#{role} -->
        ## #{ROLE_HEADINGS.fetch(role)} — #{time.strftime("%H:%M")}

      MARKER
    end

    # @return [Array<Array(Integer, Integer, Symbol)>] line index, turn number, role
    def self.scan(text)
      text.lines.each_with_index.filter_map do |line, index|
        match = PATTERN.match(line.chomp)
        [index, match[1].to_i, match[2].to_sym] if match
      end
    end

    def self.last_turn_number(text) = scan(text).map { |(_, turn, _)| turn }.max || 0
  end
end
```

Add to `lib/claude_code_md.rb`, above the existing `require_relative "claude_code_md/cli"`:

```ruby
require_relative "claude_code_md/frontmatter"
require_relative "claude_code_md/turn_marker"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rake`
Expected: all examples pass, no RuboCop offenses.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/frontmatter.rb lib/claude_code_md/turn_marker.rb spec/frontmatter_spec.rb spec/turn_marker_spec.rb
git commit -m "feat: parse conversation frontmatter and turn markers"
```

---

### Task 3: Marker vocabulary and configuration

**Files:**
- Create: `lib/claude_code_md/markers.rb`
- Create: `spec/markers_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `ClaudeCodeMd::Error`.
- Produces: `Markers.from_env(env) -> Markers`, and on an instance: `#symbols`, `#options_label`, `#enabled?`, `#show_options?`, `#prompt_symbols`, `#prompt_marker_for(line) -> String | nil`, `#indent_of(line) -> Integer | nil`, `#options_line(indent:) -> String`, `#options_line?(line) -> Boolean`, `#strip_options(text) -> String`, `#vocabulary_prompt -> String`. Raises `Markers::ConfigError` on an ambiguous boolean or a colliding options label.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/markers_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::Markers do
  it "defaults to the code-comment-threads vocabulary" do
    markers = described_class.from_env({})

    expect(markers.symbols).to eq(question: "❓", request: "❗️", reply: "💬", approve: "✅", reject: "❌")
    expect(markers).to be_enabled
    expect(markers).to be_show_options
  end

  it "takes overrides from the environment" do
    markers = described_class.from_env("CCMD_QUESTION_MARKER" => "(?)")

    expect(markers.symbols[:question]).to eq("(?)")
    expect(markers.prompt_marker_for("- (?) really?")).to eq("(?)")
  end

  it "identifies a prompt marker at the start of a list item" do
    markers = described_class.from_env({})

    expect(markers.prompt_marker_for("- ❓ a question")).to eq("❓")
    expect(markers.prompt_marker_for("  - ❗️ a request")).to eq("❗️")
    expect(markers.prompt_marker_for("- ✅ an answer")).to be_nil
    expect(markers.prompt_marker_for("❓ not a list item")).to be_nil
    expect(markers.prompt_marker_for("- text then ❓")).to be_nil
  end

  it "matches a marker whose emoji presentation selector is missing" do
    markers = described_class.from_env({})

    expect(markers.prompt_marker_for("- ❗ no variation selector")).to eq("❗️")
  end

  it "reports list indentation" do
    markers = described_class.from_env({})

    expect(markers.indent_of("- top level")).to eq(0)
    expect(markers.indent_of("    - nested")).to eq(4)
    expect(markers.indent_of("prose")).to be_nil
  end

  it "renders an options line nested under its marker" do
    line = described_class.from_env({}).options_line(indent: 0)

    expect(line).to eq("  - Options: ✅ approve · ❌ reject · 💬 reply\n")
  end

  it "recognises and strips its own options lines" do
    markers = described_class.from_env({})
    text = "- ❓ a question\n#{markers.options_line(indent: 0)}  - ✅ yes\n"

    expect(markers.strip_options(text)).to eq("- ❓ a question\n  - ✅ yes\n")
  end

  it "disables options lines when inline responses are off" do
    markers = described_class.from_env("CCMD_INLINE_RESPONSES" => "false")

    expect(markers).not_to be_enabled
    expect(markers).not_to be_show_options
  end

  it "accepts the documented boolean spellings" do
    %w[1 true yes on].each { |raw| expect(described_class.from_env("CCMD_SHOW_OPTIONS" => raw)).to be_show_options }
    %w[0 false no off].each { |raw| expect(described_class.from_env("CCMD_SHOW_OPTIONS" => raw)).not_to be_show_options }
  end

  it "rejects an ambiguous boolean rather than guessing" do
    expect { described_class.from_env("CCMD_SHOW_OPTIONS" => "maybe") }
      .to raise_error(described_class::ConfigError, /CCMD_SHOW_OPTIONS/)
  end

  it "rejects an options label that would parse as a message" do
    expect { described_class.from_env("CCMD_OPTIONS_LABEL" => "💬 choices:") }
      .to raise_error(described_class::ConfigError, /must not begin with/)
  end

  it "names the configured markers in the vocabulary prompt" do
    prompt = described_class.from_env("CCMD_QUESTION_MARKER" => "(?)").vocabulary_prompt

    expect(prompt).to include("(?)").and include("Do not write options lines")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/markers_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::Markers`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/markers.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # The marker vocabulary, borrowed from the code-comment-threads skill so the
  # same symbols mean the same things in both places, plus the switches that
  # turn inline responses and options lines on and off. Resolved once at startup
  # so every component sees identical symbols.
  class Markers
    class ConfigError < Error; end

    DEFAULTS = { question: "❓", request: "❗️", reply: "💬", approve: "✅", reject: "❌" }.freeze

    ENV_KEYS = {
      question: "CCMD_QUESTION_MARKER",
      request: "CCMD_REQUEST_MARKER",
      reply: "CCMD_REPLY_MARKER",
      approve: "CCMD_APPROVE_MARKER",
      reject: "CCMD_REJECT_MARKER"
    }.freeze

    DEFAULT_OPTIONS_LABEL = "Options:"
    PROMPT_KINDS = %i[question request].freeze
    LIST_ITEM = /\A(\s*)(?:[-*+]|\d+[.)])\s+(.*)\z/
    TRUTHY = %w[1 true yes on].freeze
    FALSEY = %w[0 false no off].freeze
    VARIATION_SELECTOR = "\uFE0F"

    attr_reader :symbols, :options_label

    def self.from_env(env = ENV)
      new(symbols: ENV_KEYS.to_h { |kind, key| [kind, env.fetch(key, DEFAULTS.fetch(kind))] },
          options_label: env.fetch("CCMD_OPTIONS_LABEL", DEFAULT_OPTIONS_LABEL),
          enabled: boolean(env, "CCMD_INLINE_RESPONSES", default: true),
          show_options: boolean(env, "CCMD_SHOW_OPTIONS", default: true))
    end

    # Ambiguous values are rejected rather than guessed, matching the skill.
    def self.boolean(env, key, default:)
      raw = env[key]
      return default if raw.nil? || raw.to_s.empty?

      normalized = raw.strip.downcase
      return true if TRUTHY.include?(normalized)
      return false if FALSEY.include?(normalized)

      raise ConfigError, "#{key} must be one of #{(TRUTHY + FALSEY).join(", ")}, got #{raw.inspect}"
    end
    private_class_method :boolean

    def initialize(symbols: DEFAULTS, options_label: DEFAULT_OPTIONS_LABEL, enabled: true, show_options: true)
      @symbols = symbols.freeze
      @options_label = options_label
      @enabled = enabled
      @show_options = show_options
      validate_options_label!
    end

    def enabled? = @enabled
    def show_options? = @show_options && @enabled
    def prompt_symbols = @symbols.values_at(*PROMPT_KINDS)

    # @return [String, nil] the prompt marker this list item begins with
    def prompt_marker_for(line)
      match = LIST_ITEM.match(line.chomp)
      return nil unless match

      body = normalize(match[2])
      prompt_symbols.find { |symbol| body.start_with?(normalize(symbol)) }
    end

    # @return [Integer, nil] leading whitespace width, nil when the line is not a list item
    def indent_of(line) = LIST_ITEM.match(line.chomp)&.then { |match| match[1].length }

    def options_line(indent:)
      approve, reject, reply = @symbols.values_at(:approve, :reject, :reply)
      "#{" " * (indent + 2)}- #{@options_label} #{approve} approve · #{reject} reject · #{reply} reply\n"
    end

    def options_line?(line) = line.include?("- #{@options_label} ")

    def strip_options(text) = text.lines.reject { |line| options_line?(line) }.join

    # Appended to CC's system prompt so it knows the vocabulary exists.
    def vocabulary_prompt
      question, request = @symbols.values_at(:question, :request)
      "You are talking to the user inside a markdown file. When you need decisions, write each " \
        "one as its own list item beginning with #{question} for a question or #{request} for a " \
        "request. The user answers beneath each item, so keep each item self-contained and " \
        "answerable on its own. Do not write options lines; the harness adds them."
    end

    private

    # Emoji presentation selectors vary between editors, so compare without them.
    def normalize(text) = text.delete(VARIATION_SELECTOR)

    def validate_options_label!
      offender = @symbols.values.find { |symbol| normalize(@options_label).start_with?(normalize(symbol)) }
      return unless offender

      raise ConfigError, "CCMD_OPTIONS_LABEL must not begin with the marker #{offender}"
    end
  end
end
```

Add `require_relative "claude_code_md/markers"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/markers.rb spec/markers_spec.rb
git commit -m "feat: resolve the inline-response marker vocabulary"
```

---

### Task 4: Trailing-block delta extraction

This is no longer the whole story of what gets sent — it is one of two inputs to `TurnComposer` in Task 7, the other being inline responses. It still owns exactly one question: what did you type in the trailing block?

**Files:**
- Create: `lib/claude_code_md/delta_extractor.rb`
- Create: `spec/delta_extractor_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `TurnMarker.scan`.
- Produces: `DeltaExtractor.call(String) -> String` and `DeltaExtractor::SEND_TOKEN == "/send"`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/delta_extractor_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::DeltaExtractor do
  def conversation(trailing)
    <<~MD
      ---
      session_id: abc-123
      ---

      <!-- ccmd:turn=1 role=me -->
      ## Me — 14:32

      first question

      <!-- ccmd:turn=1 role=cc -->
      ## CC — 14:33

      an answer

      <!-- ccmd:turn=2 role=me -->
      ## Me — 14:41

      #{trailing}
    MD
  end

  it "returns only the text after the last user marker" do
    expect(described_class.call(conversation("second question"))).to eq("second question")
  end

  it "strips a trailing send token" do
    expect(described_class.call(conversation("second question\n\n/send"))).to eq("second question")
  end

  it "preserves internal blank lines and markdown" do
    text = "line one\n\n- a bullet\n\n/send"

    expect(described_class.call(conversation(text))).to eq("line one\n\n- a bullet")
  end

  it "returns an empty string when only the send token is present" do
    expect(described_class.call(conversation("/send"))).to eq("")
  end

  it "returns an empty string when there is no user marker" do
    expect(described_class.call("just prose\n")).to eq("")
  end

  it "ignores a send token that is not the final line" do
    expect(described_class.call(conversation("/send\n\nactually this"))).to eq("/send\n\nactually this")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/delta_extractor_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::DeltaExtractor`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/delta_extractor.rb
# frozen_string_literal: true

require_relative "turn_marker"

module ClaudeCodeMd
  # Pulls the text the user typed in the trailing block: everything after the
  # final user marker's heading, minus the send token. Inline responses written
  # further up the file are found by InlineResponses, not here.
  module DeltaExtractor
    SEND_TOKEN = "/send"

    def self.call(text)
      marker_index = TurnMarker.scan(text)
                               .select { |(_, _, role)| role == :me }
                               .map(&:first)
                               .max
      return "" unless marker_index

      # Skip the marker line and the heading line that follows it.
      body = text.lines[(marker_index + 2)..] || []
      strip_send_token(body.join).strip
    end

    def self.strip_send_token(text)
      lines = text.lines
      lines.pop while lines.last && lines.last.strip.empty?
      lines.pop if lines.last&.strip == SEND_TOKEN
      lines.join
    end
    private_class_method :strip_send_token
  end
end
```

Add `require_relative "claude_code_md/delta_extractor"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/delta_extractor.rb spec/delta_extractor_spec.rb
git commit -m "feat: extract the trailing block's pending text"
```

---

### Task 5: Block index

**Files:**
- Create: `lib/claude_code_md/block_index.rb`
- Create: `spec/block_index_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `TurnMarker`, `Markers`.
- Produces: `BlockIndex.call(String) -> Array<BlockIndex::Block>`; `Block#turn`, `#role`, `#body`, `#lines`, `#prompt_line_indexes(markers) -> Array<Integer>`; `BlockIndex.outside_fences(lines) -> Array<Integer>`; raises `BlockIndex::CorruptedError` naming the line number when a heading has no marker comment above it.

Guessing block boundaries would silently send the wrong text, so corruption is a hard failure rather than a recovery.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/block_index_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::BlockIndex do
  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }

  let(:conversation) do
    <<~MD
      ---
      session_id: abc-123
      ---

      <!-- ccmd:turn=1 role=me -->
      ## Me — 14:32

      why is this flaky

      <!-- ccmd:turn=1 role=cc -->
      ## CC — 14:33

      Two things:

      - ❓ Should ls scan both locations?
      - ❗️ Confirm the poll interval.

      <!-- ccmd:turn=2 role=me -->
      ## Me — 14:41

    MD
  end

  it "splits the document into blocks in order" do
    blocks = described_class.call(conversation)

    expect(blocks.map { |block| [block.turn, block.role] }).to eq([[1, :me], [1, :cc], [2, :me]])
  end

  it "excludes the marker comment and heading from the body" do
    body = described_class.call(conversation).first.body

    expect(body).not_to include("ccmd:turn").and not_include("## Me")
    expect(body.strip).to eq("why is this flaky")
  end

  it "gives the trailing block an empty body" do
    expect(described_class.call(conversation).last.body.strip).to eq("")
  end

  it "finds prompt lines within a block" do
    cc_block = described_class.call(conversation)[1]

    expect(cc_block.prompt_line_indexes(markers).map { |index| cc_block.lines[index].strip })
      .to eq(["- ❓ Should ls scan both locations?", "- ❗️ Confirm the poll interval."])
  end

  it "ignores a marker inside a fenced code block" do
    text = <<~MD
      <!-- ccmd:turn=1 role=cc -->
      ## CC — 14:33

      ```markdown
      - ❓ this is an example, not a question
      ```

      - ❓ this one is real
    MD

    block = described_class.call(text).first

    expect(block.prompt_line_indexes(markers).size).to eq(1)
    expect(block.lines[block.prompt_line_indexes(markers).first]).to include("this one is real")
  end

  it "fails loudly when a heading has lost its marker comment" do
    text = "<!-- ccmd:turn=1 role=me -->\n## Me — 14:32\n\nhi\n\n## CC — 14:33\n\nreply\n"

    expect { described_class.call(text) }
      .to raise_error(described_class::CorruptedError, /line 6/)
  end

  it "does not mistake a heading inside a fence for a lost marker" do
    text = "<!-- ccmd:turn=1 role=cc -->\n## CC — 14:33\n\n```\n## Me — 09:00\n```\n"

    expect { described_class.call(text) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/block_index_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::BlockIndex`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/block_index.rb
# frozen_string_literal: true

require_relative "turn_marker"

module ClaudeCodeMd
  # Splits a conversation into the blocks ccmd wrote, so responses can be
  # diffed one block at a time. Fence tracking lives here so every consumer
  # agrees on which lines are prose and which are examples.
  module BlockIndex
    class CorruptedError < Error; end

    FENCE = /\A\s*(?:```|~~~)/

    # One turn's contribution to the document. `body` excludes the marker
    # comment and the heading.
    Block = Data.define(:turn, :role, :body) do
      def lines = body.lines

      # Body line indexes that begin a prompt, skipping fenced code.
      #
      # @param markers [Markers]
      def prompt_line_indexes(markers)
        BlockIndex.outside_fences(lines).select { |index| markers.prompt_marker_for(lines[index]) }
      end
    end

    # @return [Array<Block>] in document order
    def self.call(text)
      lines = text.lines
      starts = TurnMarker.scan(text)
      detect_orphan_headings(lines, starts)

      starts.each_with_index.map do |(line_index, turn, role), position|
        next_start = starts[position + 1]&.first || lines.size
        Block.new(turn: turn, role: role, body: lines[(line_index + 2)...next_start].to_a.join)
      end
    end

    # @return [Array<Integer>] indexes of lines that are not inside a code fence
    def self.outside_fences(lines)
      inside = false
      lines.each_index.select do |index|
        if FENCE.match?(lines[index])
          inside = !inside
          false
        else
          !inside
        end
      end
    end

    # A heading ccmd would have written, with no marker comment above it, means
    # the file was edited in a way that makes block boundaries unknowable.
    def self.detect_orphan_headings(lines, starts)
      expected = starts.map { |(index, _, _)| index + 1 }
      outside_fences(lines).each do |index|
        next unless TurnMarker::HEADING_PATTERN.match?(lines[index].chomp)
        next if expected.include?(index)

        raise CorruptedError, "line #{index + 1}: heading without a ccmd marker comment above it"
      end
    end
    private_class_method :detect_orphan_headings
  end
end
```

Add `require_relative "claude_code_md/block_index"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass. RSpec has no `not_include` matcher — if Step 1's compound expectation fails to parse, split it into two `expect` lines rather than inventing a matcher.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/block_index.rb spec/block_index_spec.rb
git commit -m "feat: split a conversation into ccmd-authored blocks"
```

---

### Task 6: Inline response detection

The heart of the feature. Two files: a minimal line differ, and the pairing rules that turn its output into responses.

**Files:**
- Create: `lib/claude_code_md/line_diff.rb`, `lib/claude_code_md/inline_responses.rb`
- Create: `spec/line_diff_spec.rb`, `spec/inline_responses_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `BlockIndex::Block`, `Markers`, and any object answering `#snapshot_for(turn:, role:) -> String | nil` and `#consumed?(marker_sha:, response_sha:) -> Boolean` (Task 9 supplies the real one).
- Produces:
  - `LineDiff.call(old_lines, new_lines) -> Array<LineDiff::Op>`; `Op#kind` is `:same`, `:add`, or `:del`; `Op#text`; `Op#index` is the position in the new array for `:same` and `:add`, `nil` for `:del`.
  - `InlineResponses.call(blocks:, state:, markers:) -> InlineResponses::Result`; `Result#responses -> Array<Response>`, `Result#deletions -> Array<Hash>`.
  - `Response#turn`, `#role`, `#kind` (`:answer`, `:annotation`, `:edit`), `#prompt` (`nil` unless `:answer`), `#text`, `#marker_sha`, `#response_sha`.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/line_diff_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::LineDiff do
  def kinds(old_text, new_text)
    described_class.call(old_text.lines, new_text.lines).map { |op| [op.kind, op.text.chomp] }
  end

  it "reports untouched lines as same" do
    expect(kinds("a\nb\n", "a\nb\n")).to eq([[:same, "a"], [:same, "b"]])
  end

  it "reports an inserted line as an addition" do
    expect(kinds("a\nb\n", "a\nnew\nb\n")).to eq([[:same, "a"], [:add, "new"], [:same, "b"]])
  end

  it "reports a removed line as a deletion" do
    expect(kinds("a\ngone\nb\n", "a\nb\n")).to eq([[:same, "a"], [:del, "gone"], [:same, "b"]])
  end

  it "reports a changed line as a deletion plus an addition" do
    expect(kinds("a\nold\n", "a\nnew\n")).to include([:del, "old"], [:add, "new"])
  end

  it "indexes additions by their position in the new text" do
    ops = described_class.call("a\n".lines, "a\nsecond\n".lines)

    expect(ops.last.index).to eq(1)
  end

  it "handles an empty starting point" do
    expect(kinds("", "only\n")).to eq([[:add, "only"]])
  end
end
```

```ruby
# spec/inline_responses_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::InlineResponses do
  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }

  # Stands in for ConversationState, which Task 9 builds.
  let(:state) do
    Class.new do
      def initialize(snapshots) = @snapshots = snapshots
      def snapshot_for(turn:, role:) = @snapshots[[turn, role]]
      def consumed?(marker_sha:, response_sha:) = false
    end
  end

  def snapshot_state(snapshots) = state.new(snapshots)

  def cc_block(body) = ClaudeCodeMd::BlockIndex::Block.new(turn: 3, role: :cc, body: body)

  let(:asked) do
    <<~MD
      Two things:

      - ❓ Should ls scan both locations?
      - ❗️ Confirm the poll interval.
    MD
  end

  it "pairs an answer to the question above it" do
    answered = asked.sub("- ❓ Should ls scan both locations?\n",
                         "- ❓ Should ls scan both locations?\n  - ✅ Yes\n")
    result = described_class.call(blocks: [cc_block(answered)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.size).to eq(1)
    expect(result.responses.first).to have_attributes(
      turn: 3, role: :cc, kind: :answer,
      prompt: "- ❓ Should ls scan both locations?", text: "- ✅ Yes"
    )
  end

  it "pairs several answers to their own questions" do
    answered = <<~MD
      Two things:

      - ❓ Should ls scan both locations?
        - ✅ Yes
      - ❗️ Confirm the poll interval.
        - 💬 200ms, and make it configurable.
    MD
    result = described_class.call(blocks: [cc_block(answered)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.map(&:text)).to eq(["- ✅ Yes", "- 💬 200ms, and make it configurable."])
    expect(result.responses.map { |response| response.prompt[0..4] }).to eq(["- ❓ S", "- ❗️ C"])
  end

  it "joins several lines under one question into a single response" do
    answered = asked.sub("- ❗️ Confirm the poll interval.\n",
                         "- ❗️ Confirm the poll interval.\n  - 💬 200ms\n  - and configurable\n")
    result = described_class.call(blocks: [cc_block(answered)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.map(&:text)).to eq(["- 💬 200ms\n  - and configurable"])
  end

  it "accepts a plain indented sentence as a response" do
    answered = asked.sub("- ❓ Should ls scan both locations?\n",
                         "- ❓ Should ls scan both locations?\n  yes please\n")
    result = described_class.call(blocks: [cc_block(answered)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.first.text).to eq("yes please")
  end

  it "treats a line at column zero as a block-level annotation" do
    annotated = "#{asked}\nthis whole list is premature\n"
    result = described_class.call(blocks: [cc_block(annotated)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.first).to have_attributes(kind: :annotation, prompt: nil,
                                                      text: "this whole list is premature")
  end

  it "treats a marker the user adds as a new prompt, not an answer" do
    annotated = "#{asked}- ❗️ also check the trace format\n"
    result = described_class.call(blocks: [cc_block(annotated)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.first.kind).to eq(:annotation)
  end

  it "ignores a question inside a fenced code block" do
    fenced = "#{asked}\n```markdown\n- ❓ an example\n  - ✅ not a real answer\n```\n"
    result = described_class.call(blocks: [cc_block(fenced)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.map(&:kind)).to all(eq(:annotation))
    expect(result.responses.none? { |response| response.prompt&.include?("an example") }).to be(true)
  end

  it "collects answers from two non-adjacent blocks" do
    first = ClaudeCodeMd::BlockIndex::Block.new(turn: 1, role: :cc, body: "- ❓ one?\n  - ✅ yes\n")
    second = ClaudeCodeMd::BlockIndex::Block.new(turn: 3, role: :cc, body: "- ❓ two?\n  - ❌ no\n")
    result = described_class.call(
      blocks: [first, second],
      state: snapshot_state([1, :cc] => "- ❓ one?\n", [3, :cc] => "- ❓ two?\n"),
      markers: markers
    )

    expect(result.responses.map(&:turn)).to eq([1, 3])
  end

  it "sends an edit to CC's prose as a diff and reports the deletion" do
    edited = asked.sub("Two things:", "Two things (I reworded this):")
    result = described_class.call(blocks: [cc_block(edited)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    edit = result.responses.find { |response| response.kind == :edit }

    expect(edit.text).to include("-Two things:").and include("+Two things (I reworded this):")
    expect(result.deletions.map { |deletion| deletion[:text].strip }).to include("Two things:")
  end

  it "reports a pure deletion without sending a response" do
    shortened = asked.sub("- ❗️ Confirm the poll interval.\n", "")
    result = described_class.call(blocks: [cc_block(shortened)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses.map(&:kind)).to eq([:edit])
    expect(result.deletions.size).to eq(1)
  end

  it "ignores options lines on both sides of the diff" do
    with_options = asked.sub("- ❓ Should ls scan both locations?\n",
                             "- ❓ Should ls scan both locations?\n#{markers.options_line(indent: 0)}")
    result = described_class.call(blocks: [cc_block(with_options)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses).to be_empty
  end

  it "ignores whitespace-only changes" do
    padded = "#{asked}\n\n"
    result = described_class.call(blocks: [cc_block(padded)],
                                  state: snapshot_state([[3, :cc]] => asked), markers: markers)

    expect(result.responses).to be_empty
  end

  it "skips a block it has never seen before" do
    result = described_class.call(blocks: [cc_block(asked)], state: snapshot_state({}), markers: markers)

    expect(result.responses).to be_empty
  end

  it "skips a response already recorded as consumed" do
    consuming_state = Class.new do
      def snapshot_for(turn:, role:) = "- ❓ Should ls scan both locations?\n"
      def consumed?(marker_sha:, response_sha:) = true
    end
    block = cc_block("- ❓ Should ls scan both locations?\n  - ✅ Yes\n")

    result = described_class.call(blocks: [block], state: consuming_state.new, markers: markers)

    expect(result.responses).to be_empty
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/line_diff_spec.rb spec/inline_responses_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::LineDiff`.

- [ ] **Step 3: Implement the differ**

```ruby
# lib/claude_code_md/line_diff.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # A line-based diff, which the standard library does not provide. Block bodies
  # are tens of lines, so the quadratic table costs nothing here.
  module LineDiff
    # @param index [Integer, nil] position in the new array; nil for a deletion
    Op = Data.define(:kind, :text, :index)

    # @return [Array<Op>] in new-document order
    def self.call(old_lines, new_lines)
      table = lcs_table(old_lines, new_lines)
      ops = []
      row = old_lines.size
      col = new_lines.size

      while row.positive? || col.positive?
        if row.positive? && col.positive? && old_lines[row - 1] == new_lines[col - 1]
          ops.unshift(Op.new(kind: :same, text: new_lines[col - 1], index: col - 1))
          row -= 1
          col -= 1
        elsif col.positive? && (row.zero? || table[row][col - 1] >= table[row - 1][col])
          ops.unshift(Op.new(kind: :add, text: new_lines[col - 1], index: col - 1))
          col -= 1
        else
          ops.unshift(Op.new(kind: :del, text: old_lines[row - 1], index: nil))
          row -= 1
        end
      end

      ops
    end

    def self.lcs_table(old_lines, new_lines)
      table = Array.new(old_lines.size + 1) { Array.new(new_lines.size + 1, 0) }

      old_lines.each_index do |row|
        new_lines.each_index do |col|
          table[row + 1][col + 1] = if old_lines[row] == new_lines[col]
                                      table[row][col] + 1
                                    else
                                      [table[row][col + 1], table[row + 1][col]].max
                                    end
        end
      end

      table
    end
    private_class_method :lcs_table
  end
end
```

- [ ] **Step 4: Implement the pairing rules**

```ruby
# lib/claude_code_md/inline_responses.rb
# frozen_string_literal: true

require "digest"

require_relative "block_index"
require_relative "line_diff"

module ClaudeCodeMd
  # Finds what the user wrote into blocks ccmd had already written, and pairs
  # each addition to the prompt it sits beneath.
  module InlineResponses
    # @param kind [Symbol] :answer, :annotation, or :edit
    # @param prompt [String, nil] the marker line being answered, nil otherwise
    Response = Data.define(:turn, :role, :kind, :prompt, :text, :marker_sha, :response_sha)

    Result = Data.define(:responses, :deletions)

    def self.call(blocks:, state:, markers:)
      responses = []
      deletions = []

      blocks.each do |block|
        snapshot = state.snapshot_for(turn: block.turn, role: block.role)
        next if snapshot.nil?

        diff_block(block, snapshot, markers, responses, deletions)
      end

      Result.new(responses: reject_consumed(responses, state), deletions: deletions)
    end

    def self.diff_block(block, snapshot, markers, responses, deletions)
      old_lines = markers.strip_options(snapshot).lines
      new_lines = markers.strip_options(block.body).lines
      return if old_lines == new_lines

      ops = LineDiff.call(old_lines, new_lines)
      additions = ops.select { |op| op.kind == :add && !op.text.strip.empty? }
      removals = ops.select { |op| op.kind == :del && !op.text.strip.empty? }

      responses.concat(pair_additions(block, new_lines, additions, markers))
      return if removals.empty?

      deletions.concat(removals.map { |op| { turn: block.turn, role: block.role, text: op.text } })
      responses << edit_response(block, ops)
    end

    # Walk upward from each addition to the nearest prompt line indented less
    # than it is. Additions sharing a prompt are joined in document order.
    def self.pair_additions(block, new_lines, additions, markers)
      prompt_indexes = BlockIndex.outside_fences(new_lines)
                                 .select { |index| markers.prompt_marker_for(new_lines[index]) }
      added_indexes = additions.map(&:index)

      additions.group_by { |op| prompt_for(op, prompt_indexes, added_indexes, new_lines) }
               .map { |prompt_index, ops| build_response(block, new_lines, prompt_index, ops) }
    end

    def self.prompt_for(addition, prompt_indexes, added_indexes, new_lines)
      indent = leading_width(addition.text)
      return nil if indent.zero?

      prompt_indexes.reverse.find do |index|
        # A prompt the user just added is a new question, not something to answer.
        next false if added_indexes.include?(index)

        index < addition.index && leading_width(new_lines[index]) < indent
      end
    end

    def self.build_response(block, new_lines, prompt_index, ops)
      prompt = prompt_index && new_lines[prompt_index].chomp
      text = ops.sort_by(&:index).map { |op| op.text.chomp }.join("\n")

      Response.new(turn: block.turn, role: block.role,
                   kind: prompt ? :answer : :annotation,
                   prompt: prompt, text: text,
                   marker_sha: sha(prompt.to_s), response_sha: sha(text))
    end

    def self.edit_response(block, ops)
      text = ops.reject { |op| op.kind == :same }.map do |op|
        "#{op.kind == :add ? "+" : "-"}#{op.text.chomp}"
      end.join("\n")

      Response.new(turn: block.turn, role: block.role, kind: :edit, prompt: nil,
                   text: text, marker_sha: sha("edit"), response_sha: sha(text))
    end

    def self.reject_consumed(responses, state)
      responses.reject do |response|
        state.consumed?(marker_sha: response.marker_sha, response_sha: response.response_sha)
      end
    end

    def self.leading_width(line) = line[/\A[ \t]*/].length
    def self.sha(text) = Digest::SHA256.hexdigest(text)

    private_class_method :diff_block, :pair_additions, :prompt_for, :build_response,
                         :edit_response, :reject_consumed, :leading_width, :sha
  end
end
```

Add `require_relative "claude_code_md/line_diff"` and `require_relative "claude_code_md/inline_responses"` to `lib/claude_code_md.rb`.

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rake`
Expected: all pass. The fenced-example spec is the one most likely to need adjustment — additions inside a fence still count as additions, they simply cannot pair to a fenced prompt, so they arrive as annotations.

- [ ] **Step 6: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/line_diff.rb lib/claude_code_md/inline_responses.rb spec/line_diff_spec.rb spec/inline_responses_spec.rb
git commit -m "feat: detect answers written beneath CC's questions"
```

---

### Task 7: Turn composer

**Files:**
- Create: `lib/claude_code_md/turn_composer.rb`
- Create: `spec/turn_composer_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `InlineResponses::Response`.
- Produces: `TurnComposer.call(responses:, trailing_text:) -> String`, empty when there is nothing to send.

The prompt text is quoted back so CC never has to re-read the file to know what is being answered.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/turn_composer_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::TurnComposer do
  def response(kind:, text:, prompt: nil, turn: 3)
    ClaudeCodeMd::InlineResponses::Response.new(
      turn: turn, role: :cc, kind: kind, prompt: prompt, text: text,
      marker_sha: "m", response_sha: "r"
    )
  end

  it "returns an empty string when there is nothing to send" do
    expect(described_class.call(responses: [], trailing_text: "  \n")).to eq("")
  end

  it "sends the trailing text alone when there are no responses" do
    expect(described_class.call(responses: [], trailing_text: "just a question"))
      .to eq("[new message]\n\njust a question")
  end

  it "sends responses alone when the trailing block is empty" do
    payload = described_class.call(
      responses: [response(kind: :answer, prompt: "- ❓ Should ls scan both?", text: "- ✅ Yes")],
      trailing_text: ""
    )

    expect(payload).to eq("[inline responses]\n\nturn 3 · ❓ Should ls scan both?\n  - ✅ Yes")
  end

  it "quotes the prompt without its list bullet" do
    payload = described_class.call(
      responses: [response(kind: :answer, prompt: "  - ❗️ Confirm the interval.", text: "- 💬 200ms")],
      trailing_text: ""
    )

    expect(payload).to include("turn 3 · ❗️ Confirm the interval.")
  end

  it "labels annotations and edits" do
    payload = described_class.call(
      responses: [response(kind: :annotation, text: "this list is premature"),
                  response(kind: :edit, text: "-old\n+new")],
      trailing_text: ""
    )

    expect(payload).to include("turn 3 · annotation").and include("turn 3 · edit to text ccmd wrote")
  end

  it "indents multi-line response text" do
    payload = described_class.call(
      responses: [response(kind: :annotation, text: "first\nsecond")], trailing_text: ""
    )

    expect(payload).to include("  first\n  second")
  end

  it "puts both sections in order when both exist" do
    payload = described_class.call(
      responses: [response(kind: :answer, prompt: "- ❓ one?", text: "- ✅ Yes")],
      trailing_text: "Also bump the poll interval."
    )

    expect(payload).to eq(<<~PAYLOAD.strip)
      [inline responses]

      turn 3 · ❓ one?
        - ✅ Yes

      [new message]

      Also bump the poll interval.
    PAYLOAD
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/turn_composer_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::TurnComposer`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/turn_composer.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # Merges inline responses and the trailing block's text into the single
  # message a turn sends. Only the parts that exist appear.
  module TurnComposer
    INLINE_HEADER = "[inline responses]"
    MESSAGE_HEADER = "[new message]"
    LIST_BULLET = /\A\s*(?:[-*+]|\d+[.)])\s+/

    def self.call(responses:, trailing_text:)
      sections = []
      sections << "#{INLINE_HEADER}\n\n#{render(responses)}" unless responses.empty?
      sections << "#{MESSAGE_HEADER}\n\n#{trailing_text.to_s.strip}" unless blank?(trailing_text)
      sections.join("\n\n")
    end

    def self.render(responses)
      responses.map { |response| "#{heading(response)}\n#{indent(response.text)}" }.join("\n\n")
    end

    def self.heading(response)
      case response.kind
      when :answer then "turn #{response.turn} · #{response.prompt.sub(LIST_BULLET, "")}"
      when :edit then "turn #{response.turn} · edit to text ccmd wrote"
      else "turn #{response.turn} · annotation"
      end
    end

    def self.indent(text) = text.lines.map { |line| "  #{line.chomp}" }.join("\n")
    def self.blank?(text) = text.to_s.strip.empty?

    private_class_method :render, :heading, :indent, :blank?
  end
end
```

Add `require_relative "claude_code_md/turn_composer"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/turn_composer.rb spec/turn_composer_spec.rb
git commit -m "feat: compose inline responses and typed text into one turn"
```

---

### Task 8: Event codec

**Files:**
- Create: `lib/claude_code_md/event_codec.rb`
- Create: `spec/event_codec_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: fixtures from Task 1.
- Produces: `EventCodec.encode_user(String, session_id:) -> String` (one line, no newline); `EventCodec.decode(String) -> Event | nil`; `Event#type`, `#subtype`, `#raw`, `#text_delta`, `#thinking_delta`, `#tool_uses`, `#tool_results`, `#session_id`, `#result?`, `#error?`, `#duration_ms`, `#num_turns`, `#total_cost_usd`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/event_codec_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::EventCodec do
  def fixture_events(name)
    path = File.expand_path("fixtures/#{name}.jsonl", __dir__)
    File.readlines(path).filter_map { |line| described_class.decode(line) }
  end

  describe ".encode_user" do
    it "produces a single line carrying the text and session" do
      line = described_class.encode_user("hello", session_id: "abc-123")

      expect(line).not_to include("\n")
      expect(JSON.parse(line)).to eq(
        "type" => "user",
        "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "hello" }] },
        "parent_tool_use_id" => nil,
        "session_id" => "abc-123"
      )
    end

    it "escapes newlines and quotes so a composed payload survives" do
      payload = "[inline responses]\n\nturn 3 · ❓ \"quoted\"\n  - ✅ Yes"
      line = described_class.encode_user(payload, session_id: "abc-123")

      expect(line).not_to include("\n")
      expect(JSON.parse(line).dig("message", "content", 0, "text")).to eq(payload)
    end
  end

  describe ".decode" do
    it "returns nil for an unparseable line" do
      expect(described_class.decode("not json")).to be_nil
    end

    it "reassembles streamed prose from a real fixture" do
      prose = fixture_events("text_only").filter_map(&:text_delta).join

      expect(prose).to include("hello there friend")
    end

    it "finds the terminating result event" do
      result = fixture_events("text_only").find(&:result?)

      expect(result).not_to be_nil
      expect(result).not_to be_error
      expect(result.session_id).to match(/\A[0-9a-f-]{36}\z/)
      expect(result.duration_ms).to be_a(Integer)
    end

    it "exposes tool uses and their results" do
      events = fixture_events("with_tools")

      expect(events.flat_map(&:tool_uses).map { |use| use["name"] }).to include("Bash")
      expect(events.flat_map(&:tool_results)).not_to be_empty
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/event_codec_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::EventCodec`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/event_codec.rb
# frozen_string_literal: true

require "json"

module ClaudeCodeMd
  # Translates between CC's stream-json protocol and plain Ruby values. Pure: it
  # touches neither the filesystem nor the child process.
  module EventCodec
    # One decoded line of CC stdout. `raw` is kept so unmodeled fields stay
    # reachable without widening this class.
    Event = Data.define(:type, :subtype, :raw) do
      def text_delta = delta_of("text_delta", "text")
      def thinking_delta = delta_of("thinking_delta", "thinking")

      def tool_uses = content_blocks("assistant", "tool_use")
      def tool_results = content_blocks("user", "tool_result")

      def session_id = raw["session_id"]
      def result? = type == "result"
      def error? = result? && raw["is_error"] == true
      def duration_ms = raw["duration_ms"]
      def num_turns = raw["num_turns"]
      def total_cost_usd = raw["total_cost_usd"]

      private

      def delta_of(delta_type, key)
        return nil unless type == "stream_event"

        delta = raw.dig("event", "delta")
        delta[key] if delta.is_a?(Hash) && delta["type"] == delta_type
      end

      def content_blocks(expected_type, block_type)
        return [] unless type == expected_type

        blocks = raw.dig("message", "content")
        return [] unless blocks.is_a?(Array)

        blocks.select { |block| block["type"] == block_type }
      end
    end

    # @param text [String] the composed payload, which may contain newlines
    def self.encode_user(text, session_id:)
      JSON.generate(
        type: "user",
        message: { role: "user", content: [{ type: "text", text: text }] },
        parent_tool_use_id: nil,
        session_id: session_id
      )
    end

    # @return [Event, nil] nil when the line is not valid JSON
    def self.decode(line)
      raw = JSON.parse(line)
      return nil unless raw.is_a?(Hash)

      Event.new(type: raw["type"], subtype: raw["subtype"], raw: raw)
    rescue JSON::ParserError
      nil
    end
  end
end
```

Add `require_relative "claude_code_md/event_codec"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass. If the thinking delta type recorded in the fixtures README differs from `thinking_delta`, change the string here to match it and note why in a comment.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/event_codec.rb spec/event_codec_spec.rb
git commit -m "feat: encode and decode the CC stream-json protocol"
```

---

### Task 9: Conversation state

**Files:**
- Create: `lib/claude_code_md/conversation_state.rb`
- Create: `spec/conversation_state_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `BlockIndex::Block`, `InlineResponses::Response`, `Markers#strip_options`.
- Produces: `ConversationState.load(path:, blocks:, markers:) -> ConversationState`; `#snapshot_for(turn:, role:) -> String | nil`; `#consumed?(marker_sha:, response_sha:) -> Boolean`; `#mark_consumed(responses)`; `#advance(blocks)`; `#save`; `#path`; raises `ConversationState::VersionError` for a state file from a newer version.

This is the one file ccmd rewrites wholesale, which is safe because the user never has it open. Writes go to a temporary file in the same directory and are renamed into place, so a crash mid-write leaves the previous state intact.

A missing state file is recoverable: snapshots seed from the current blocks, which makes everything already-consumed and produces no spurious resend.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/conversation_state_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::ConversationState do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }
  let(:path) { File.join(@dir, "c.state.json") }

  def block(turn:, role:, body:) = ClaudeCodeMd::BlockIndex::Block.new(turn: turn, role: role, body: body)

  def response(marker_sha:, response_sha:)
    ClaudeCodeMd::InlineResponses::Response.new(
      turn: 1, role: :cc, kind: :answer, prompt: "- ❓ q", text: "- ✅ y",
      marker_sha: marker_sha, response_sha: response_sha
    )
  end

  def load(blocks) = described_class.load(path: path, blocks: blocks, markers: markers)

  it "seeds snapshots from the current blocks when there is no state file" do
    state = load([block(turn: 1, role: :cc, body: "- ❓ q\n")])

    expect(state.snapshot_for(turn: 1, role: :cc)).to eq("- ❓ q\n")
  end

  it "returns nil for a block it has no snapshot of" do
    expect(load([]).snapshot_for(turn: 9, role: :cc)).to be_nil
  end

  it "strips options lines from stored snapshots" do
    body = "- ❓ q\n#{markers.options_line(indent: 0)}"
    state = load([block(turn: 1, role: :cc, body: body)])

    expect(state.snapshot_for(turn: 1, role: :cc)).to eq("- ❓ q\n")
  end

  it "persists snapshots across a save and reload" do
    load([block(turn: 1, role: :cc, body: "original\n")]).save
    reloaded = load([block(turn: 1, role: :cc, body: "edited by hand\n")])

    expect(reloaded.snapshot_for(turn: 1, role: :cc)).to eq("original\n")
  end

  it "advances snapshots to the current blocks" do
    state = load([block(turn: 1, role: :cc, body: "original\n")])
    state.advance([block(turn: 1, role: :cc, body: "answered\n")])

    expect(state.snapshot_for(turn: 1, role: :cc)).to eq("answered\n")
  end

  it "remembers a consumed response by both hashes" do
    state = load([])
    state.mark_consumed([response(marker_sha: "m1", response_sha: "r1")])

    expect(state.consumed?(marker_sha: "m1", response_sha: "r1")).to be(true)
    expect(state.consumed?(marker_sha: "m1", response_sha: "r2")).to be(false)
  end

  it "persists consumed entries across a reload" do
    state = load([])
    state.mark_consumed([response(marker_sha: "m1", response_sha: "r1")])
    state.save

    expect(load([]).consumed?(marker_sha: "m1", response_sha: "r1")).to be(true)
  end

  it "writes atomically, leaving no temporary file behind" do
    load([]).save

    expect(Dir.children(@dir)).to eq(["c.state.json"])
  end

  it "ignores a temporary file left by an interrupted write" do
    File.write("#{path}.tmp", "{ this is not valid json")
    state = load([block(turn: 1, role: :cc, body: "body\n")])

    expect(state.snapshot_for(turn: 1, role: :cc)).to eq("body\n")
  end

  it "refuses a state file from a newer version rather than misreading it" do
    File.write(path, JSON.generate("version" => described_class::VERSION + 1, "blocks" => []))

    expect { load([]) }.to raise_error(described_class::VersionError, /version/)
  end

  it "treats a corrupt state file as missing" do
    File.write(path, "{ truncated")
    state = load([block(turn: 1, role: :cc, body: "body\n")])

    expect(state.snapshot_for(turn: 1, role: :cc)).to eq("body\n")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/conversation_state_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::ConversationState`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/conversation_state.rb
# frozen_string_literal: true

require "json"
require "pathname"

module ClaudeCodeMd
  # Snapshots of every block as ccmd last saw it, plus the responses already
  # sent. Diffing a block against its snapshot is how an answer written under a
  # question gets noticed.
  #
  # Consumed entries are keyed by marker hash *and* response hash: marker alone
  # would suppress a corrected answer, response alone would confuse identical
  # answers to different questions.
  class ConversationState
    class VersionError < Error; end

    VERSION = 1

    attr_reader :path

    # A missing or unreadable state file is not fatal — snapshots seed from the
    # current blocks, so nothing diffs as new and nothing is re-sent.
    def self.load(path:, blocks:, markers:)
      stored = read(Pathname.new(path))
      raise VersionError, "state file version #{stored["version"]} is newer than #{VERSION}" if newer?(stored)

      new(path: path, markers: markers,
          snapshots: stored ? snapshots_from(stored) : seed(blocks, markers),
          consumed: stored ? consumed_from(stored) : [])
    end

    def self.read(path)
      return nil unless path.exist?

      parsed = JSON.parse(path.read)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def self.newer?(stored) = stored && stored["version"].to_i > VERSION

    def self.snapshots_from(stored)
      Array(stored["blocks"]).to_h { |entry| [[entry["turn"], entry["role"].to_sym], entry["text"].to_s] }
    end

    def self.consumed_from(stored)
      Array(stored["consumed"]).map { |entry| [entry["marker_sha256"], entry["response_sha256"]] }
    end

    def self.seed(blocks, markers)
      blocks.to_h { |block| [[block.turn, block.role], markers.strip_options(block.body)] }
    end

    private_class_method :read, :newer?, :snapshots_from, :consumed_from, :seed

    def initialize(path:, markers:, snapshots: {}, consumed: [])
      @path = Pathname.new(path)
      @markers = markers
      @snapshots = snapshots
      @consumed = consumed
    end

    # @return [String, nil] nil when this block has never been snapshotted
    def snapshot_for(turn:, role:) = @snapshots[[turn, role]]

    def consumed?(marker_sha:, response_sha:) = @consumed.include?([marker_sha, response_sha])

    def mark_consumed(responses)
      responses.each { |response| @consumed << [response.marker_sha, response.response_sha] }
      @consumed.uniq!
      self
    end

    # Called at turn end, when the file is quiescent. Anything added while a
    # turn streamed is therefore picked up on the following send.
    def advance(blocks)
      blocks.each { |block| @snapshots[[block.turn, block.role]] = @markers.strip_options(block.body) }
      self
    end

    def save
      temporary = @path.dirname.join("#{@path.basename}.tmp")
      @path.dirname.mkpath
      temporary.write("#{JSON.pretty_generate(document)}\n")
      temporary.rename(@path.to_s)
      self
    end

    private

    def document
      { "version" => VERSION,
        "blocks" => @snapshots.map do |(turn, role), text|
          { "turn" => turn, "role" => role.to_s, "text" => text }
        end,
        "consumed" => @consumed.map do |(marker_sha, response_sha)|
          { "marker_sha256" => marker_sha, "response_sha256" => response_sha }
        end }
    end
  end
end
```

Add `require_relative "claude_code_md/conversation_state"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/conversation_state.rb spec/conversation_state_spec.rb
git commit -m "feat: snapshot blocks and remember consumed responses"
```

---

### Task 10: Conversation file

**Files:**
- Create: `lib/claude_code_md/conversation_file.rb`
- Create: `spec/conversation_file_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `Frontmatter`, `TurnMarker`, `DeltaExtractor`, `BlockIndex`.
- Produces: `ConversationFile.new(path)` with `#path`, `#exist?`, `#read`, `#frontmatter`, `#pending_text`, `#blocks`, `#trace_path`, `#state_path`, `#create(session_id:, cwd:, model:, permission_mode:, now:)`, `#open_turn(role:, now:)`, `#append(text)`, `#append_note(text)`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/conversation_file_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::ConversationFile do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:path) { File.join(@dir, "nested", "conversation.md") }
  let(:file) { described_class.new(path) }
  let(:now) { Time.new(2026, 8, 5, 14, 32, 0) }

  def created
    file.create(session_id: "abc-123", cwd: "/tmp/repo", model: "opus", permission_mode: "auto", now: now)
  end

  it "creates parent directories, frontmatter, and an opening user turn" do
    created

    expect(file.frontmatter).to include(session_id: "abc-123", cwd: "/tmp/repo", model: "opus")
    expect(file.read).to end_with("<!-- ccmd:turn=1 role=me -->\n## Me — 14:32\n\n")
  end

  it "does not overwrite an existing file" do
    created
    file.append("typed by hand\n")
    file.create(session_id: "different", cwd: "/x", model: "sonnet", permission_mode: "auto", now: now)

    expect(file.frontmatter[:session_id]).to eq("abc-123")
    expect(file.read).to include("typed by hand")
  end

  it "numbers a CC turn to match the user turn it answers" do
    created
    file.open_turn(role: :cc, now: now)

    expect(file.read).to include("<!-- ccmd:turn=1 role=cc -->")

    file.open_turn(role: :me, now: now)

    expect(file.read).to include("<!-- ccmd:turn=2 role=me -->")
  end

  it "appends after content added underneath it by someone else" do
    created
    File.write(path, "#{File.read(path)}a line the user typed\n")
    file.append("streamed reply")

    expect(file.read).to end_with("a line the user typed\nstreamed reply")
  end

  it "reports the pending user text" do
    created
    file.append("what is this\n\n/send\n")

    expect(file.pending_text).to eq("what is this")
  end

  it "exposes its blocks" do
    created
    file.append("a question\n")
    file.open_turn(role: :cc, now: now)

    expect(file.blocks.map(&:role)).to eq(%i[me cc])
  end

  it "derives sibling paths from the conversation path" do
    expect(file.trace_path.to_s).to eq(File.join(@dir, "nested", "conversation.trace.md"))
    expect(file.state_path.to_s).to eq(File.join(@dir, "nested", "conversation.state.json"))
  end

  it "formats a note as a blockquote" do
    created
    file.append_note("interrupted")

    expect(file.read).to end_with("\n> interrupted\n\n")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/conversation_file_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::ConversationFile`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/conversation_file.rb
# frozen_string_literal: true

require "pathname"

require_relative "block_index"
require_relative "delta_extractor"
require_relative "frontmatter"
require_relative "turn_marker"

module ClaudeCodeMd
  # The conversation document itself. Every write is an append, which is what
  # makes it safe to edit higher up in the file while a turn is streaming: the
  # OS places our bytes at the current end of file either way.
  class ConversationFile
    attr_reader :path

    def initialize(path)
      @path = Pathname.new(path)
    end

    def exist? = path.exist?
    def read = path.read
    def frontmatter = Frontmatter.parse(read)
    def pending_text = DeltaExtractor.call(read)
    def blocks = BlockIndex.call(read)
    def trace_path = path.sub_ext(".trace.md")
    def state_path = path.sub_ext(".state.json")

    # Creates the file with frontmatter and an opening user turn. A file that
    # already exists is left exactly as it is.
    def create(session_id:, cwd:, model:, permission_mode:, now: Time.now)
      return self if exist?

      path.dirname.mkpath
      path.write(Frontmatter.render(
                   session_id: session_id,
                   cwd: cwd.to_s,
                   model: model,
                   permission_mode: permission_mode,
                   created: now.strftime("%-m/%-d/%Y %H:%M")
                 ))
      open_turn(role: :me, now: now)
      self
    end

    # @param role [Symbol] :me or :cc
    def open_turn(role:, now: Time.now)
      append(TurnMarker.render(turn: next_turn_number(role), role: role, time: now))
    end

    def append(text)
      path.open("a") { |io| io.write(text) }
    end

    # Out-of-band messages from ccmd itself — interruptions, resumes, errors.
    def append_note(text)
      append("\n> #{text}\n\n")
    end

    private

    # A CC turn carries the same number as the user turn it answers.
    def next_turn_number(role)
      last = TurnMarker.last_turn_number(read)
      role == :me ? last + 1 : last
    end
  end
end
```

Add `require_relative "claude_code_md/conversation_file"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/conversation_file.rb spec/conversation_file_spec.rb
git commit -m "feat: append-only conversation file"
```

---

### Task 11: Trace file

**Files:**
- Create: `lib/claude_code_md/trace_file.rb`
- Create: `spec/trace_file_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `TraceFile.new(path)` with `#path`, `#read`, `#anchor(turn)`, `#start_turn(turn:, now:)`, `#append(text)`, `#record_payload(text)`, `#tool_use(name:, input:)`, `#tool_result(content:, max_bytes:)`, `#finish_turn(duration_ms:, num_turns:, total_cost_usd:)`.

Recording the composed payload verbatim is what makes "what did ccmd actually send?" answerable without guessing.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/trace_file_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::TraceFile do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:trace) { described_class.new(File.join(@dir, "conversation.trace.md")) }
  let(:now) { Time.new(2026, 8, 5, 14, 33, 0) }

  it "starts a turn with a heading the conversation can link to" do
    trace.start_turn(turn: 3, now: now)

    expect(trace.read).to include("## Turn 3 — 14:33")
    expect(trace.anchor(3)).to eq("#turn-3")
  end

  it "records the composed payload verbatim in a collapsed block" do
    trace.record_payload("[inline responses]\n\nturn 3 · ❓ one?\n  - ✅ Yes")

    expect(trace.read).to include("<details><summary>Sent</summary>")
    expect(trace.read).to include("turn 3 · ❓ one?")
  end

  it "records a tool use with its input" do
    trace.tool_use(name: "Bash", input: { "command" => "echo hi" })

    expect(trace.read).to include("### `Bash`").and include("echo hi")
  end

  it "wraps a tool result in a collapsed details block" do
    trace.tool_result(content: "line one\nline two\n", max_bytes: nil)

    expect(trace.read).to include("<details><summary>Result — 2 lines</summary>")
    expect(trace.read).to include("line two")
  end

  it "truncates a result only when a cap is given" do
    trace.tool_result(content: "x" * 100, max_bytes: 10)

    expect(trace.read).to include("x" * 10).and include("truncated")
    expect(trace.read).not_to include("x" * 11)
  end

  it "footers a turn with its timings" do
    trace.finish_turn(duration_ms: 13_068, num_turns: 2, total_cost_usd: 0.0412)

    expect(trace.read).to include("Duration 13.1s · 2 turns · $0.0412")
  end

  it "omits cost when CC did not report it" do
    trace.finish_turn(duration_ms: 1500, num_turns: 1, total_cost_usd: nil)

    expect(trace.read).to include("Duration 1.5s · 1 turn")
    expect(trace.read).not_to include("$")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/trace_file_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::TraceFile`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/trace_file.rb
# frozen_string_literal: true

require "json"
require "pathname"

module ClaudeCodeMd
  # The sibling document holding what was sent, what CC thought, and what its
  # tools did. Tool results are recorded in full by default: the trace is built
  # from output CC already streamed, is never read back into a session, and so
  # costs no tokens.
  class TraceFile
    attr_reader :path

    def initialize(path)
      @path = Pathname.new(path)
    end

    def read = path.exist? ? path.read : ""
    def anchor(turn) = "#turn-#{turn}"

    def start_turn(turn:, now: Time.now)
      append("## Turn #{turn} — #{now.strftime("%H:%M")}\n\n")
    end

    def append(text)
      path.dirname.mkpath
      path.open("a") { |io| io.write(text) }
    end

    def record_payload(text)
      append("<details><summary>Sent</summary>\n\n```\n#{text}\n```\n\n</details>\n\n")
    end

    def tool_use(name:, input:)
      append("### `#{name}`\n\n```json\n#{JSON.pretty_generate(input)}\n```\n\n")
    end

    # @param max_bytes [Integer, nil] nil records the whole result
    def tool_result(content:, max_bytes: nil)
      body = content.to_s
      count = body.lines.size
      summary = "Result — #{count} #{count == 1 ? "line" : "lines"}"
      body = "#{body.byteslice(0, max_bytes)}\n… truncated at #{max_bytes} bytes" if truncate?(body, max_bytes)

      append("<details><summary>#{summary}</summary>\n\n```\n#{body}\n```\n\n</details>\n\n")
    end

    def finish_turn(duration_ms:, num_turns:, total_cost_usd: nil)
      parts = ["Duration #{format("%.1f", duration_ms.to_i / 1000.0)}s",
               "#{num_turns} #{num_turns == 1 ? "turn" : "turns"}"]
      parts << format("$%.4f", total_cost_usd) if total_cost_usd

      append("#{parts.join(" · ")}\n\n")
    end

    private

    def truncate?(body, max_bytes) = max_bytes && body.bytesize > max_bytes
  end
end
```

Add `require_relative "claude_code_md/trace_file"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/trace_file.rb spec/trace_file_spec.rb
git commit -m "feat: trace what was sent, thought, and run"
```

---

### Task 12: Send gate

**Files:**
- Create: `lib/claude_code_md/send_gate.rb`
- Create: `spec/send_gate_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `DeltaExtractor::SEND_TOKEN`.
- Produces: `SendGate.new(conversation_path)` with `#poll -> :sidecar | :token | nil` and `#sidecar_path -> Pathname`.

A token-triggered send keeps matching until something is appended after it, so `Session` must open the CC turn before polling again. That ordering is asserted in Task 18.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/send_gate_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::SendGate do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:path) { File.join(@dir, "conversation.md") }
  let(:gate) { described_class.new(path) }

  it "stays quiet for a file that is merely saved" do
    File.write(path, "## Me — 14:32\n\nhalf a thought\n")

    expect(gate.poll).to be_nil
    expect(gate.poll).to be_nil
  end

  it "fires once for a sidecar and deletes it" do
    File.write(path, "anything\n")
    FileUtils.touch("#{path}.send")

    expect(gate.poll).to eq(:sidecar)
    expect(gate.poll).to be_nil
    expect(File.exist?("#{path}.send")).to be(false)
  end

  it "fires for a trailing send token" do
    File.write(path, "a question\n\n/send\n")

    expect(gate.poll).to eq(:token)
  end

  it "ignores a send token that is not the last non-empty line" do
    File.write(path, "/send\n\nmore text\n")

    expect(gate.poll).to be_nil
  end

  it "fires on a sidecar even when the trailing block is empty" do
    File.write(path, "<!-- ccmd:turn=2 role=me -->\n## Me — 14:41\n\n")
    FileUtils.touch("#{path}.send")

    expect(gate.poll).to eq(:sidecar)
  end

  it "stays quiet when the conversation does not exist yet" do
    expect(gate.poll).to be_nil
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/send_gate_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::SendGate`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/send_gate.rb
# frozen_string_literal: true

require "pathname"

require_relative "delta_extractor"

module ClaudeCodeMd
  # Decides whether the user meant to send. Saving is not a signal — it happens
  # constantly — so the gate looks only for deliberate acts: the sidecar that
  # cmd+enter touches, or a send token typed as the final line.
  class SendGate
    def initialize(conversation_path)
      @conversation = Pathname.new(conversation_path)
      @sidecar = Pathname.new("#{conversation_path}.send")
    end

    def sidecar_path = @sidecar

    # @return [Symbol, nil] :sidecar, :token, or nil
    def poll
      if @sidecar.exist?
        @sidecar.delete
        return :sidecar
      end

      :token if trailing_send_token?
    end

    private

    def trailing_send_token?
      return false unless @conversation.exist?

      last = @conversation.read.lines.reject { |line| line.strip.empty? }.last
      last&.strip == DeltaExtractor::SEND_TOKEN
    end
  end
end
```

Add `require_relative "claude_code_md/send_gate"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/send_gate.rb spec/send_gate_spec.rb
git commit -m "feat: gate sends on deliberate intent, not on save"
```

---

### Task 13: Location resolution

**Files:**
- Create: `lib/claude_code_md/location.rb`
- Create: `spec/location_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Location.resolve(target, dir:, shape:, env:, cwd:, now:) -> Pathname`; `Location.directories(env:, cwd:) -> {repo: Pathname | nil, global: Pathname}`; `Location.repo_root(cwd) -> Pathname | nil`.

Implement exactly the resolution table in the base design's Conversation Location section.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/location_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::Location do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:now) { Time.new(2026, 8, 5, 14, 32, 0) }
  let(:env) { { "HOME" => @dir } }

  def repo_with_nested_dir
    FileUtils.mkdir_p(File.join(@dir, "repo", ".git"))
    FileUtils.mkdir_p(nested = File.join(@dir, "repo", "app", "models"))
    nested
  end

  it "uses a path argument verbatim" do
    result = described_class.resolve("notes/chat.md", env: env, cwd: @dir, now: now)

    expect(result.to_s).to eq(File.join(@dir, "notes/chat.md"))
  end

  it "honours an explicit directory over everything else" do
    result = described_class.resolve("flaky-spec", dir: File.join(@dir, "elsewhere"), env: env, cwd: @dir, now: now)

    expect(result.to_s).to eq(File.join(@dir, "elsewhere", "conversation.8_5_2026.flaky_spec.md"))
  end

  it "resolves a slug against the repo root when inside a repo" do
    result = described_class.resolve("flaky-spec", env: env, cwd: repo_with_nested_dir, now: now)

    expect(result.to_s).to eq(
      File.join(@dir, "repo", "docs/agent-local/conversations", "conversation.8_5_2026.flaky_spec.md")
    )
  end

  it "falls back to the global directory outside a repo" do
    result = described_class.resolve("flaky-spec", env: env, cwd: @dir, now: now)

    expect(result.to_s).to eq(File.join(@dir, "trunk/docs/conversations", "conversation.8_5_2026.flaky_spec.md"))
  end

  it "forces the global shape when asked" do
    result = described_class.resolve("x", shape: :global, env: env, cwd: repo_with_nested_dir, now: now)

    expect(result.to_s).to start_with(File.join(@dir, "trunk/docs/conversations"))
  end

  it "reads overrides from the environment" do
    custom = env.merge("CCMD_REPO_SUBDIR" => "tmp/chats", "CCMD_LOCATION" => "repo")
    result = described_class.resolve("x", env: custom, cwd: repo_with_nested_dir, now: now)

    expect(result.to_s).to eq(File.join(@dir, "repo", "tmp/chats", "conversation.8_5_2026.x.md"))
  end

  it "finds the repo root from a nested directory" do
    expect(described_class.repo_root(repo_with_nested_dir).to_s).to eq(File.join(@dir, "repo"))
  end

  it "returns nil for a repo root outside a repository" do
    expect(described_class.repo_root(@dir)).to be_nil
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/location_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::Location`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/location.rb
# frozen_string_literal: true

require "pathname"

module ClaudeCodeMd
  # Works out which file a conversation argument refers to. A path is used as
  # given; a bare slug resolves inside either a repo-relative or a global
  # directory, both configurable.
  module Location
    DEFAULT_REPO_SUBDIR = "docs/agent-local/conversations"
    DEFAULT_GLOBAL_SUBPATH = "trunk/docs/conversations"

    # @param target [String] a path or a slug
    # @param dir [String, nil] explicit directory, which wins over every other source
    # @param shape [Symbol, nil] :repo or :global, forced by flag
    def self.resolve(target, dir: nil, shape: nil, env: ENV, cwd: Dir.pwd, now: Time.now)
      return Pathname.new(cwd).join(target).cleanpath if path_like?(target)

      base = dir ? Pathname.new(cwd).join(dir) : directory_for(shape, env: env, cwd: cwd)
      base.join(filename_for(target, now))
    end

    # @return [Hash] :repo is nil when cwd is not inside a repository
    def self.directories(env: ENV, cwd: Dir.pwd)
      root = repo_root(cwd)
      { repo: root&.join(env.fetch("CCMD_REPO_SUBDIR", DEFAULT_REPO_SUBDIR)),
        global: global_directory(env) }
    end

    def self.repo_root(cwd)
      Pathname.new(cwd).expand_path.ascend { |dir| return dir if dir.join(".git").exist? }
      nil
    end

    def self.path_like?(target) = target.include?("/") || target.end_with?(".md")

    def self.directory_for(shape, env:, cwd:)
      dirs = directories(env: env, cwd: cwd)
      shape ||= env["CCMD_LOCATION"]&.to_sym || (dirs[:repo] ? :repo : :global)

      shape == :repo && dirs[:repo] ? dirs[:repo] : dirs[:global]
    end

    def self.global_directory(env)
      configured = env["CCMD_GLOBAL_DIR"]
      return Pathname.new(configured) if configured

      Pathname.new(env.fetch("HOME")).join(DEFAULT_GLOBAL_SUBPATH)
    end

    def self.filename_for(slug, now)
      "conversation.#{now.strftime("%-m_%-d_%Y")}.#{slug.tr("-", "_")}.md"
    end

    private_class_method :path_like?, :directory_for, :global_directory, :filename_for
  end
end
```

Add `require_relative "claude_code_md/location"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/location.rb spec/location_spec.rb
git commit -m "feat: resolve conversation paths from slugs, flags, and env"
```

---

### Task 14: Conversation index

**Files:**
- Create: `lib/claude_code_md/conversation_index.rb`
- Create: `spec/conversation_index_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `Location.directories`, `ConversationFile#frontmatter`.
- Produces: `ConversationIndex.entries(env:, cwd:, all:) -> Array<Hash>` with keys `:path`, `:session_id`, `:updated_at`, newest first.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/conversation_index_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::ConversationIndex do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:env) { { "HOME" => @dir, "CCMD_GLOBAL_DIR" => File.join(@dir, "global") } }

  def write_conversation(dir, name, session_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "---\nsession_id: #{session_id}\n---\n\n")
  end

  it "lists conversations in the resolved directory, newest first" do
    write_conversation(File.join(@dir, "global"), "conversation.8_4_2026.older.md", "aaa")
    sleep(0.01)
    write_conversation(File.join(@dir, "global"), "conversation.8_5_2026.newer.md", "bbb")

    entries = described_class.entries(env: env, cwd: @dir)

    expect(entries.map { |entry| entry[:session_id] }).to eq(%w[bbb aaa])
    expect(entries.first[:updated_at]).to be_a(Time)
  end

  it "ignores trace and state siblings" do
    write_conversation(File.join(@dir, "global"), "conversation.8_5_2026.x.md", "aaa")
    File.write(File.join(@dir, "global", "conversation.8_5_2026.x.trace.md"), "## Turn 1\n")
    File.write(File.join(@dir, "global", "conversation.8_5_2026.x.state.json"), "{}")

    expect(described_class.entries(env: env, cwd: @dir).size).to eq(1)
  end

  it "scans both locations with all" do
    FileUtils.mkdir_p(File.join(@dir, "repo", ".git"))
    write_conversation(File.join(@dir, "repo", "docs/agent-local/conversations"),
                       "conversation.8_5_2026.r.md", "rrr")
    write_conversation(File.join(@dir, "global"), "conversation.8_5_2026.g.md", "ggg")

    entries = described_class.entries(env: env, cwd: File.join(@dir, "repo"), all: true)

    expect(entries.map { |entry| entry[:session_id] }).to contain_exactly("rrr", "ggg")
  end

  it "returns nothing when no directory exists yet" do
    expect(described_class.entries(env: env, cwd: @dir)).to be_empty
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/conversation_index_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::ConversationIndex`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/conversation_index.rb
# frozen_string_literal: true

require_relative "conversation_file"
require_relative "location"

module ClaudeCodeMd
  # Finds existing conversations so `ccmd ls` has something to show.
  module ConversationIndex
    SIBLING_SUFFIXES = [".trace.md", ".state.json"].freeze

    # @param all [Boolean] true scans both the repo-relative and global directories
    def self.entries(env: ENV, cwd: Dir.pwd, all: false)
      directories(env: env, cwd: cwd, all: all)
        .flat_map { |dir| conversations_in(dir) }
        .sort_by { |entry| -entry[:updated_at].to_f }
    end

    def self.directories(env:, cwd:, all:)
      dirs = Location.directories(env: env, cwd: cwd)
      return dirs.values.compact.uniq if all

      [dirs[:repo] || dirs[:global]]
    end

    def self.conversations_in(dir)
      return [] unless dir&.directory?

      dir.glob("*.md").reject { |path| sibling?(path) }.map do |path|
        { path: path,
          session_id: ConversationFile.new(path).frontmatter[:session_id],
          updated_at: path.mtime }
      end
    end

    def self.sibling?(path) = SIBLING_SUFFIXES.any? { |suffix| path.to_s.end_with?(suffix) }

    private_class_method :directories, :conversations_in, :sibling?
  end
end
```

Add `require_relative "claude_code_md/conversation_index"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/conversation_index.rb spec/conversation_index_spec.rb
git commit -m "feat: index existing conversations"
```

---

### Task 15: Claude process

**Files:**
- Create: `lib/claude_code_md/claude_process.rb`
- Create: `spec/claude_process_spec.rb`
- Create: `spec/support/fake_claude.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `EventCodec`, `Markers#enabled?`, `Markers#vocabulary_prompt`.
- Produces: `ClaudeProcess.new(session_id:, cwd:, model:, permission_mode:, markers:, executable:)` with `#command(resume:)`, `#start(resume:)`, `#send_user(text)`, `#events -> Thread::Queue`, `#alive?`, `#stop`.

`#interrupt` is deliberately absent: the control-protocol field shapes are unverified, so Ctrl+C stops the child and the next turn resumes with `--resume`.

- [ ] **Step 1: Write the fake executable and the failing spec**

```ruby
# spec/support/fake_claude.rb
#!/usr/bin/env ruby
# frozen_string_literal: true

# Stands in for the real `claude` binary. Reads one JSON line per turn on stdin
# and replays the fixture named by FAKE_CLAUDE_FIXTURE for each one, so specs
# exercise the streaming path without spending tokens.
$stdout.sync = true

fixture = ENV.fetch("FAKE_CLAUDE_FIXTURE")
File.write(ENV["FAKE_CLAUDE_ARGV"], ARGV.join("\n")) if ENV["FAKE_CLAUDE_ARGV"]
File.write(ENV["FAKE_CLAUDE_CWD"], Dir.pwd) if ENV["FAKE_CLAUDE_CWD"]

while (line = $stdin.gets)
  File.write(ENV["FAKE_CLAUDE_STDIN"], line) if ENV["FAKE_CLAUDE_STDIN"]
  File.foreach(fixture) { |event| $stdout.puts(event) }
end
```

```ruby
# spec/claude_process_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::ClaudeProcess do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:fake) { File.expand_path("support/fake_claude.rb", __dir__) }
  let(:fixture) { File.expand_path("fixtures/text_only.jsonl", __dir__) }
  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }

  def process(cwd: @dir, markers: self.markers)
    described_class.new(session_id: "abc-123", cwd: cwd, model: "opus",
                        permission_mode: "auto", markers: markers, executable: fake)
  end

  it "builds the verified invocation" do
    command = process.command(resume: false)

    expect(command).to include("-p", "--verbose", "--input-format", "stream-json",
                               "--output-format", "stream-json", "--include-partial-messages",
                               "--session-id", "abc-123", "--model", "opus",
                               "--permission-mode", "auto")
    expect(command).not_to include("--resume")
  end

  it "swaps session-id for resume when resuming" do
    command = process.command(resume: true)

    expect(command).to include("--resume", "abc-123")
    expect(command).not_to include("--session-id")
  end

  it "teaches CC the marker vocabulary" do
    command = process.command(resume: false)
    fragment = command[command.index("--append-system-prompt") + 1]

    expect(fragment).to include("❓").and include("Do not write options lines")
  end

  it "omits the vocabulary when inline responses are disabled" do
    disabled = ClaudeCodeMd::Markers.from_env("CCMD_INLINE_RESPONSES" => "false")

    expect(process(markers: disabled).command(resume: false)).not_to include("--append-system-prompt")
  end

  it "streams decoded events for a turn and terminates with a result" do
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
    subject = process
    subject.start
    subject.send_user("hello")

    events = []
    events << subject.events.pop until events.last&.result?

    expect(events.filter_map(&:text_delta).join).to include("hello there friend")
    subject.stop
  ensure
    ENV.delete("FAKE_CLAUDE_FIXTURE")
  end

  it "runs the child in the requested directory" do
    FileUtils.mkdir_p(target = File.join(@dir, "repo"))
    probe = File.join(@dir, "cwd.txt")
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
    ENV["FAKE_CLAUDE_CWD"] = probe
    subject = process(cwd: target)
    subject.start
    subject.send_user("hello")
    subject.events.pop until subject.events.empty?
    subject.stop

    expect(File.read(probe)).to eq(target)
  ensure
    ENV.delete("FAKE_CLAUDE_FIXTURE")
    ENV.delete("FAKE_CLAUDE_CWD")
  end

  it "sends the payload verbatim on one line" do
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
    ENV["FAKE_CLAUDE_STDIN"] = (probe = File.join(@dir, "stdin.txt"))
    subject = process
    subject.start
    subject.send_user("[inline responses]\n\nturn 3 · ❓ one?\n  - ✅ Yes")
    subject.events.pop until subject.events.empty?
    subject.stop

    sent = JSON.parse(File.read(probe))

    expect(sent.dig("message", "content", 0, "text")).to include("turn 3 · ❓ one?")
  ensure
    ENV.delete("FAKE_CLAUDE_FIXTURE")
    ENV.delete("FAKE_CLAUDE_STDIN")
  end

  it "is not alive once stopped" do
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
    subject = process
    subject.start
    subject.stop

    expect(subject).not_to be_alive
  ensure
    ENV.delete("FAKE_CLAUDE_FIXTURE")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/claude_process_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::ClaudeProcess`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/claude_process.rb
# frozen_string_literal: true

require "open3"

require_relative "event_codec"

module ClaudeCodeMd
  # The long-lived `claude` child. One process holds the session for the life of
  # the conversation, so a turn costs no re-reading of history.
  #
  # A reader thread owns stdout and pushes decoded events onto {#events}; the
  # caller's thread owns every file write. That split is why nothing races on
  # the conversation file.
  class ClaudeProcess
    STREAM_FLAGS = %w[
      -p --verbose
      --input-format stream-json
      --output-format stream-json
      --include-partial-messages
    ].freeze

    attr_reader :events

    def initialize(session_id:, cwd:, model:, permission_mode:, markers:, executable: "claude")
      @session_id = session_id
      @cwd = cwd.to_s
      @model = model
      @permission_mode = permission_mode
      @markers = markers
      @executable = executable
      @events = Thread::Queue.new
    end

    # @param resume [Boolean] true attaches to an existing session instead of declaring a new id
    def command(resume: false)
      session_flags = resume ? ["--resume", @session_id] : ["--session-id", @session_id]
      vocabulary = @markers.enabled? ? ["--append-system-prompt", @markers.vocabulary_prompt] : []

      [@executable, *STREAM_FLAGS, *session_flags,
       "--model", @model, "--permission-mode", @permission_mode, *vocabulary]
    end

    def start(resume: false)
      @stdin, stdout, stderr, @wait = Open3.popen3(*command(resume: resume), chdir: @cwd)
      @reader = Thread.new { pump(stdout) }
      @stderr_reader = Thread.new { stderr.each_line { |line| warn(line) } }
      self
    end

    def send_user(text)
      @stdin.puts(EventCodec.encode_user(text, session_id: @session_id))
      @stdin.flush
    end

    def alive? = @wait&.alive? || false

    def stop
      @stdin.close if @stdin && !@stdin.closed?
      @wait&.join
      @reader&.join
      @stderr_reader&.kill
      self
    end

    private

    def pump(stdout)
      stdout.each_line do |line|
        event = EventCodec.decode(line)
        @events.push(event) if event
      end
    ensure
      @events.push(:eof)
    end
  end
end
```

Add `require_relative "claude_code_md/claude_process"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass. If a spec hangs, the reader thread never reached `:eof` — check that `stop` closes stdin before joining.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/claude_process.rb spec/claude_process_spec.rb spec/support/fake_claude.rb
git commit -m "feat: supervise the long-lived claude child and teach it the markers"
```

---

### Task 16: Transcript renderer and prose stream

Options lines cannot be written by `ConversationFile`, because deciding whether a line is a prompt requires a *complete* line and prose arrives as deltas. `ProseStream` buffers to line boundaries and is the only thing that writes CC's prose.

**Files:**
- Create: `lib/claude_code_md/prose_stream.rb`, `lib/claude_code_md/transcript_renderer.rb`
- Create: `spec/prose_stream_spec.rb`, `spec/transcript_renderer_spec.rb`
- Modify: `lib/claude_code_md.rb`
- Modify: `docs/designs/design.8_5_2026.inline_responses.md`

**Interfaces:**
- Consumes: `ConversationFile`, `TraceFile`, `Markers`, `EventCodec::Event`, `InlineResponses::Response`.
- Produces:
  - `ProseStream.new(conversation:, markers:)` with `#write(text)` and `#flush`.
  - `TranscriptRenderer.new(conversation:, trace:, markers:, max_bytes:)` with `#begin_turn(now:, consumed:)`, `#record_sent(payload)`, `#handle(event, now:) -> :continue | :finished`.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/prose_stream_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::ProseStream do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }
  let(:conversation) { ClaudeCodeMd::ConversationFile.new(File.join(@dir, "c.md")) }
  let(:stream) { described_class.new(conversation: conversation, markers: markers) }

  before { File.write(File.join(@dir, "c.md"), "") }

  it "writes prose as complete lines arrive" do
    stream.write("Because the ")
    stream.write("factory memoizes.\n")

    expect(conversation.read).to eq("Because the factory memoizes.\n")
  end

  it "holds an incomplete line until flushed" do
    stream.write("no newline yet")

    expect(conversation.read).to eq("")

    stream.flush

    expect(conversation.read).to eq("no newline yet")
  end

  it "adds an options line beneath a question" do
    stream.write("- ❓ Should ls scan both?\n")

    expect(conversation.read).to eq("- ❓ Should ls scan both?\n  - Options: ✅ approve · ❌ reject · 💬 reply\n")
  end

  it "indents the options line to match a nested question" do
    stream.write("  - ❗️ Confirm the interval.\n")

    expect(conversation.read).to include("\n    - Options:")
  end

  it "leaves ordinary prose and answered markers alone" do
    stream.write("just prose\n")
    stream.write("- ✅ not a prompt\n")

    expect(conversation.read).not_to include("Options:")
  end

  it "writes no options lines when they are switched off" do
    quiet = described_class.new(conversation: conversation,
                                markers: ClaudeCodeMd::Markers.from_env("CCMD_SHOW_OPTIONS" => "false"))
    quiet.write("- ❓ Should ls scan both?\n")

    expect(conversation.read).not_to include("Options:")
  end
end
```

```ruby
# spec/transcript_renderer_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::TranscriptRenderer do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:now) { Time.new(2026, 8, 5, 14, 33, 0) }
  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }
  let(:conversation) { ClaudeCodeMd::ConversationFile.new(File.join(@dir, "c.md")) }
  let(:trace) { ClaudeCodeMd::TraceFile.new(File.join(@dir, "c.trace.md")) }
  let(:renderer) do
    described_class.new(conversation: conversation, trace: trace, markers: markers)
  end

  def event(hash) = ClaudeCodeMd::EventCodec::Event.new(type: hash["type"], subtype: hash["subtype"], raw: hash)

  def text_event(text)
    event("type" => "stream_event",
          "event" => { "type" => "content_block_delta",
                       "delta" => { "type" => "text_delta", "text" => text } })
  end

  def result_event(is_error: false, subtype: "success")
    event("type" => "result", "subtype" => subtype, "is_error" => is_error,
          "duration_ms" => 13_068, "num_turns" => 2)
  end

  def response(kind:, prompt:, turn: 1)
    ClaudeCodeMd::InlineResponses::Response.new(turn: turn, role: :cc, kind: kind, prompt: prompt,
                                                text: "- ✅ y", marker_sha: "m", response_sha: "r")
  end

  before do
    conversation.create(session_id: "abc-123", cwd: @dir, model: "opus", permission_mode: "auto", now: now)
  end

  it "opens a CC turn in the conversation and a turn in the trace" do
    renderer.begin_turn(now: now)

    expect(conversation.read).to include("<!-- ccmd:turn=1 role=cc -->")
    expect(trace.read).to include("## Turn 1 — 14:33")
  end

  it "acknowledges the inline responses it consumed" do
    renderer.begin_turn(now: now, consumed: [response(kind: :answer, prompt: "- ❓ one?"),
                                            response(kind: :answer, prompt: "- ❓ two?"),
                                            response(kind: :answer, prompt: "- ❗️ three?")])

    expect(conversation.read).to include("> Answering ❓×2 and ❗️×1 from turn 1.")
  end

  it "writes no acknowledgment when nothing was consumed" do
    renderer.begin_turn(now: now, consumed: [])

    expect(conversation.read).not_to include("Answering")
  end

  it "records what was sent in the trace only" do
    renderer.begin_turn(now: now)
    renderer.record_sent("[new message]\n\nhello")

    expect(trace.read).to include("hello")
    expect(conversation.read).not_to include("[new message]")
  end

  it "streams prose into the conversation only" do
    renderer.begin_turn(now: now)
    renderer.handle(text_event("Because the "), now: now)
    renderer.handle(text_event("factory memoizes.\n"), now: now)

    expect(conversation.read).to end_with("Because the factory memoizes.\n")
    expect(trace.read).not_to include("factory")
  end

  it "adds options lines to questions CC streams" do
    renderer.begin_turn(now: now)
    renderer.handle(text_event("- ❓ Should ls scan both?\n"), now: now)

    expect(conversation.read).to include("- Options: ✅ approve")
  end

  it "routes tool activity to the trace only" do
    renderer.begin_turn(now: now)
    renderer.handle(event("type" => "assistant", "message" => {
                            "content" => [{ "type" => "tool_use", "name" => "Bash",
                                            "input" => { "command" => "echo hi" } }]
                          }), now: now)
    renderer.handle(event("type" => "user", "message" => {
                            "content" => [{ "type" => "tool_result", "content" => "hi\n" }]
                          }), now: now)

    expect(trace.read).to include("### `Bash`").and include("echo hi")
    expect(conversation.read).not_to include("echo hi")
  end

  it "closes the turn on a result, flushing prose, linking the trace, opening the next user turn" do
    renderer.begin_turn(now: now)
    renderer.handle(text_event("no trailing newline"), now: now)
    outcome = renderer.handle(result_event, now: now)

    expect(outcome).to eq(:finished)
    expect(conversation.read).to include("no trailing newline")
    expect(conversation.read).to include("[trace](c.trace.md#turn-1)")
    expect(conversation.read).to end_with("<!-- ccmd:turn=2 role=me -->\n## Me — 14:33\n\n")
    expect(trace.read).to include("Duration 13.1s · 2 turns")
  end

  it "records an errored result in the conversation so the reason is visible" do
    renderer.begin_turn(now: now)
    renderer.handle(result_event(is_error: true, subtype: "error_during_execution"), now: now)

    expect(conversation.read).to include("> ⚠️ error_during_execution")
  end

  it "ignores events it has no sink for" do
    renderer.begin_turn(now: now)

    expect(renderer.handle(event("type" => "rate_limit_event"), now: now)).to eq(:continue)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/prose_stream_spec.rb spec/transcript_renderer_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::ProseStream`.

- [ ] **Step 3: Implement the prose stream**

```ruby
# lib/claude_code_md/prose_stream.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # Buffers streamed prose to line boundaries, which is what makes it possible
  # to notice that CC just wrote a question and add an options line beneath it.
  # Deltas arrive mid-line, so no line-level decision can be made before this.
  class ProseStream
    def initialize(conversation:, markers:)
      @conversation = conversation
      @markers = markers
      @buffer = +""
    end

    def write(text)
      @buffer << text
      while (break_at = @buffer.index("\n"))
        emit(@buffer.slice!(0..break_at))
      end
    end

    # Writes a trailing partial line, which a turn ending without a newline leaves behind.
    def flush
      return if @buffer.empty?

      @conversation.append(@buffer)
      @buffer = +""
    end

    private

    def emit(line)
      @conversation.append(line)
      return unless @markers.show_options?
      return unless @markers.prompt_marker_for(line)

      @conversation.append(@markers.options_line(indent: @markers.indent_of(line) || 0))
    end
  end
end
```

- [ ] **Step 4: Implement the renderer**

```ruby
# lib/claude_code_md/transcript_renderer.rb
# frozen_string_literal: true

require_relative "prose_stream"
require_relative "turn_marker"

module ClaudeCodeMd
  # Routes decoded events to the two sinks: prose to the conversation, thinking,
  # tool activity, and the payload that was sent to the trace.
  class TranscriptRenderer
    def initialize(conversation:, trace:, markers:, max_bytes: nil)
      @conversation = conversation
      @trace = trace
      @markers = markers
      @max_bytes = max_bytes
      @thinking_open = false
    end

    # @param consumed [Array<InlineResponses::Response>] answers this turn is carrying
    def begin_turn(now: Time.now, consumed: [])
      @turn = TurnMarker.last_turn_number(@conversation.read)
      @conversation.open_turn(role: :cc, now: now)
      @conversation.append_note(acknowledgment(consumed)) if consumed.any?
      @prose = ProseStream.new(conversation: @conversation, markers: @markers)
      @trace.start_turn(turn: @turn, now: now)
    end

    def record_sent(payload)
      @trace.record_payload(payload)
    end

    # @return [Symbol] :finished once the turn's result event arrives, else :continue
    def handle(event, now: Time.now)
      return finish(event, now: now) if event.result?

      if (thinking = event.thinking_delta)
        open_thinking
        @trace.append(thinking)
        return :continue
      end

      close_thinking
      @prose.write(event.text_delta) if event.text_delta
      render_tools(event)
      :continue
    end

    private

    def render_tools(event)
      event.tool_uses.each { |use| @trace.tool_use(name: use["name"], input: use["input"]) }
      event.tool_results.each do |result|
        @trace.tool_result(content: stringify(result["content"]), max_bytes: @max_bytes)
      end
    end

    # Tool results arrive either as a string or as an array of content blocks.
    def stringify(content)
      return content if content.is_a?(String)

      Array(content).map { |block| block.is_a?(Hash) ? block["text"] : block }.join
    end

    def open_thinking
      return if @thinking_open

      @trace.append("<details><summary>Thinking</summary>\n\n")
      @thinking_open = true
    end

    def close_thinking
      return unless @thinking_open

      @trace.append("\n\n</details>\n\n")
      @thinking_open = false
    end

    def acknowledgment(consumed)
      counts = consumed.group_by { |response| symbol_for(response) }.transform_values(&:size)
      turns = consumed.map(&:turn).uniq.sort
      label = turns.size == 1 ? "turn" : "turns"

      "Answering #{sentence(counts.map { |symbol, count| "#{symbol}×#{count}" })} from #{label} #{turns.join(", ")}."
    end

    def symbol_for(response)
      return @markers.symbols[:reply] unless response.kind == :answer

      @markers.prompt_marker_for(response.prompt) || @markers.symbols[:reply]
    end

    def sentence(parts)
      return parts.join(" and ") if parts.size <= 2

      "#{parts[0..-2].join(", ")} and #{parts.last}"
    end

    def finish(event, now:)
      close_thinking
      @prose.flush
      @conversation.append_note("⚠️ #{event.subtype}") if event.error?
      @conversation.append("\n[trace](#{@trace.path.basename}#{@trace.anchor(@turn)})\n")
      @trace.finish_turn(duration_ms: event.duration_ms, num_turns: event.num_turns,
                         total_cost_usd: event.total_cost_usd)
      @conversation.open_turn(role: :me, now: now)
      :finished
    end
  end
end
```

Add `require_relative "claude_code_md/prose_stream"` and `require_relative "claude_code_md/transcript_renderer"` to `lib/claude_code_md.rb`.

- [ ] **Step 5: Correct the design, then commit**

In `docs/designs/design.8_5_2026.inline_responses.md`, change the `ConversationFile` row of the Modified Components table so options-line rendering is attributed to `ProseStream`, and note that line-boundary buffering is why. Then:

```bash
git add lib/claude_code_md.rb lib/claude_code_md/prose_stream.rb lib/claude_code_md/transcript_renderer.rb spec/prose_stream_spec.rb spec/transcript_renderer_spec.rb docs/designs/design.8_5_2026.inline_responses.md
git commit -m "feat: stream prose with options lines and route the rest to the trace"
```

---

### Task 17: Turn state

**Files:**
- Create: `lib/claude_code_md/turn_state.rb`
- Create: `spec/turn_state_spec.rb`
- Modify: `lib/claude_code_md.rb`
- Modify: `docs/designs/design.8_5_2026.ccmd_architecture.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `TurnState.new` with `#idle?`, `#streaming?`, `#submit(payload) -> :sent | :queued | nil`, `#finish -> String | nil`.

The base design describes `idle → streaming → tool-wait → done`. Nothing behaves differently during tool-wait — the renderer handles tool events identically whether prose has started or not — so this collapses to two states. Step 5 corrects the design rather than leaving the two out of sync.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/turn_state_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::TurnState do
  subject(:state) { described_class.new }

  it "starts idle" do
    expect(state).to be_idle
  end

  it "sends the first submission and becomes streaming" do
    expect(state.submit("first")).to eq(:sent)
    expect(state).to be_streaming
  end

  it "queues submissions that arrive mid-turn" do
    state.submit("first")

    expect(state.submit("second")).to eq(:queued)
    expect(state.submit("third")).to eq(:queued)
  end

  it "hands back queued payloads in order as turns finish" do
    state.submit("first")
    state.submit("second")
    state.submit("third")

    expect(state.finish).to eq("second")
    expect(state).to be_streaming
    expect(state.finish).to eq("third")
    expect(state.finish).to be_nil
    expect(state).to be_idle
  end

  it "ignores an empty submission" do
    expect(state.submit("   ")).to be_nil
    expect(state).to be_idle
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/turn_state_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::TurnState`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/turn_state.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # Tracks whether a turn is in flight and holds anything sent while one is.
  # Two states only: no behavior differs during a tool call, so a separate
  # tool-wait state would carry no information.
  class TurnState
    def initialize
      @streaming = false
      @queued = []
    end

    def idle? = !@streaming
    def streaming? = @streaming

    # @return [Symbol, nil] :sent when the caller should transmit now, :queued
    #   when it is held for later, nil when there was nothing to send
    def submit(payload)
      return nil if payload.nil? || payload.strip.empty?

      if @streaming
        @queued << payload
        :queued
      else
        @streaming = true
        :sent
      end
    end

    # @return [String, nil] the next queued payload, or nil when going idle
    def finish
      next_payload = @queued.shift
      @streaming = !next_payload.nil?
      next_payload
    end
  end
end
```

Add `require_relative "claude_code_md/turn_state"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Correct the design, then commit**

In `docs/designs/design.8_5_2026.ccmd_architecture.md`, change the `TurnState` row of the Components table to `idle → streaming; queue turns arriving mid-flight`, and change the Concurrency section's mention of four states to two.

```bash
git add lib/claude_code_md.rb lib/claude_code_md/turn_state.rb spec/turn_state_spec.rb docs/designs/design.8_5_2026.ccmd_architecture.md
git commit -m "feat: track in-flight turns and queue mid-turn submissions"
```

---

### Task 18: Session orchestrator

**Files:**
- Create: `lib/claude_code_md/session.rb`
- Create: `spec/session_spec.rb`
- Modify: `lib/claude_code_md.rb`
- Modify: `docs/designs/design.8_5_2026.inline_responses.md`

**Interfaces:**
- Consumes: every component from Tasks 6–17.
- Produces: `Session.new(conversation:, trace:, gate:, process:, renderer:, turn_state:, conversation_state:, markers:, poll_interval:, reporter:)` with `#run(iterations: nil)` and `#tick -> :idle | :sent | :finished | :dead`.

`#run(iterations:)` exists so specs can drive a bounded number of loop passes instead of racing a background thread. `reporter` receives deletion notices; it defaults to `$stderr` and keeps housekeeping out of the document.

Two ordering rules the specs pin down:

1. The CC turn is opened **before** returning to the poll loop, so a token send stops matching.
2. Snapshots advance **after** the turn finishes, so anything typed while it streamed is picked up next time.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/session_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::Session do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:now) { Time.new(2026, 8, 5, 14, 32, 0) }
  let(:path) { File.join(@dir, "c.md") }
  let(:markers) { ClaudeCodeMd::Markers.from_env({}) }
  let(:conversation) { ClaudeCodeMd::ConversationFile.new(path) }
  let(:trace) { ClaudeCodeMd::TraceFile.new(conversation.trace_path) }
  let(:gate) { ClaudeCodeMd::SendGate.new(path) }
  let(:reporter) { StringIO.new }

  let(:process) do
    ClaudeCodeMd::ClaudeProcess.new(session_id: "abc-123", cwd: @dir, model: "opus",
                                    permission_mode: "auto", markers: markers,
                                    executable: File.expand_path("support/fake_claude.rb", __dir__))
  end

  let(:conversation_state) do
    ClaudeCodeMd::ConversationState.load(path: conversation.state_path,
                                         blocks: conversation.blocks, markers: markers)
  end

  let(:session) do
    described_class.new(
      conversation: conversation, trace: trace, gate: gate, process: process,
      renderer: ClaudeCodeMd::TranscriptRenderer.new(conversation: conversation, trace: trace,
                                                     markers: markers),
      turn_state: ClaudeCodeMd::TurnState.new, conversation_state: conversation_state,
      markers: markers, poll_interval: 0, reporter: reporter
    )
  end

  before do
    ENV["FAKE_CLAUDE_FIXTURE"] = File.expand_path("fixtures/text_only.jsonl", __dir__)
    ENV["FAKE_CLAUDE_STDIN"] = File.join(@dir, "stdin.txt")
    conversation.create(session_id: "abc-123", cwd: @dir, model: "opus", permission_mode: "auto", now: now)
    process.start
  end

  after do
    process.stop
    ENV.delete("FAKE_CLAUDE_FIXTURE")
    ENV.delete("FAKE_CLAUDE_STDIN")
  end

  def sent_payload = JSON.parse(File.read(ENV.fetch("FAKE_CLAUDE_STDIN"))).dig("message", "content", 0, "text")

  it "does nothing while the user is only typing and saving" do
    conversation.append("half a thought\n")

    expect(session.tick).to eq(:idle)
    expect(conversation.read).not_to include("role=cc")
  end

  it "runs a full turn when the sidecar appears" do
    conversation.append("why is this flaky\n")
    FileUtils.touch(gate.sidecar_path)

    expect(session.tick).to eq(:sent)
    session.run(iterations: 200)

    expect(conversation.read).to include("hello there friend")
    expect(conversation.read).to include("[trace](c.trace.md#turn-1)")
    expect(conversation.read).to end_with("<!-- ccmd:turn=2 role=me -->\n## Me — #{now.strftime("%H:%M")}\n\n")
  end

  it "opens the CC turn before polling again, so a token send fires once" do
    conversation.append("a question\n\n/send\n")

    expect(session.tick).to eq(:sent)
    expect(session.tick).not_to eq(:sent)
  end

  it "sends an inline answer with no trailing text at all" do
    conversation.append("- ❓ Should ls scan both?\n")
    conversation_state.advance(conversation.blocks).save
    conversation.append("  - ✅ Yes\n")
    FileUtils.touch(gate.sidecar_path)

    expect(session.tick).to eq(:sent)
    expect(sent_payload).to include("[inline responses]").and include("- ✅ Yes")
    expect(sent_payload).not_to include("[new message]")
  end

  it "acknowledges consumed answers in the CC block" do
    conversation.append("- ❓ Should ls scan both?\n")
    conversation_state.advance(conversation.blocks).save
    conversation.append("  - ✅ Yes\n")
    FileUtils.touch(gate.sidecar_path)
    session.tick

    expect(conversation.read).to include("> Answering ❓×1 from turn 1.")
  end

  it "does not re-send an answer after the turn completes" do
    conversation.append("- ❓ Should ls scan both?\n")
    conversation_state.advance(conversation.blocks).save
    conversation.append("  - ✅ Yes\n")
    FileUtils.touch(gate.sidecar_path)
    session.tick
    session.run(iterations: 200)

    FileUtils.touch(gate.sidecar_path)

    expect(session.tick).not_to eq(:sent)
  end

  it "reports deletions to the reporter rather than to the document" do
    conversation.append("a line CC wrote\n")
    conversation_state.advance(conversation.blocks).save
    File.write(path, conversation.read.sub("a line CC wrote\n", ""))
    FileUtils.touch(gate.sidecar_path)
    session.tick

    expect(reporter.string).to include("a line CC wrote")
  end

  it "reports a dead child" do
    process.stop

    expect(session.run(iterations: 50)).to eq(:dead)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/session_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::Session`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/session.rb
# frozen_string_literal: true

require_relative "inline_responses"
require_relative "turn_composer"

module ClaudeCodeMd
  # The watch loop. Interleaves polling for a send signal with draining the
  # events the reader thread has queued, and does every file write itself so
  # nothing else races on the conversation.
  class Session
    DEFAULT_POLL_INTERVAL = 0.15
    EMPTY_RESULT = InlineResponses::Result.new(responses: [], deletions: []).freeze

    def initialize(conversation:, trace:, gate:, process:, renderer:, turn_state:,
                   conversation_state:, markers:, poll_interval: DEFAULT_POLL_INTERVAL,
                   reporter: $stderr)
      @conversation = conversation
      @trace = trace
      @gate = gate
      @process = process
      @renderer = renderer
      @turn_state = turn_state
      @conversation_state = conversation_state
      @markers = markers
      @poll_interval = poll_interval
      @reporter = reporter
      @response_sets = {}
    end

    # @param iterations [Integer, nil] nil loops until the child dies
    def run(iterations: nil)
      count = 0
      loop do
        outcome = tick
        return outcome if outcome == :dead
        break if iterations && (count += 1) >= iterations

        sleep(@poll_interval) if @poll_interval.positive?
      end
      :idle
    end

    # One pass: deliver a pending send, then drain whatever has arrived.
    def tick
      return :dead unless @process.alive? || !@process.events.empty?
      return :sent if deliver_pending_turn == :sent

      drain_events
    end

    private

    def deliver_pending_turn
      return nil unless @gate.poll

      found = detect_inline_responses
      report(found.deletions)
      payload = TurnComposer.call(responses: found.responses, trailing_text: @conversation.pending_text)
      return nil if payload.empty?
      return nil if @turn_state.submit(payload) != :sent

      @response_sets[payload] = found.responses
      consume(found.responses)
      transmit(payload)
      :sent
    end

    def detect_inline_responses
      return EMPTY_RESULT unless @markers.enabled?

      InlineResponses.call(blocks: @conversation.blocks, state: @conversation_state, markers: @markers)
    end

    # Recorded at send time so re-saving before the turn ends cannot double-send.
    def consume(responses)
      return if responses.empty?

      @conversation_state.mark_consumed(responses).save
    end

    def transmit(payload)
      # The CC turn must be open before the loop polls again, or a token send
      # would still be the last non-empty line and fire a second time.
      @renderer.begin_turn(consumed: @response_sets.fetch(payload, []))
      @renderer.record_sent(payload)
      @process.send_user(payload)
    end

    def drain_events
      outcome = :idle
      until @process.events.empty?
        event = @process.events.pop
        return :dead if event == :eof

        next unless @renderer.handle(event) == :finished

        outcome = :finished
        complete_turn
      end
      outcome
    end

    # Snapshots advance only here, so anything typed while the turn streamed is
    # picked up on the next send rather than this one.
    def complete_turn
      @conversation_state.advance(@conversation.blocks).save
      queued = @turn_state.finish
      return unless queued

      transmit(queued)
    end

    def report(deletions)
      deletions.each do |deletion|
        @reporter.puts("deleted from turn #{deletion[:turn]} #{deletion[:role]}: #{deletion[:text].strip}")
      end
    end
  end
end
```

Add `require_relative "claude_code_md/session"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Correct the design, then commit**

In `docs/designs/design.8_5_2026.inline_responses.md`, change the `ConversationFile` row so state updates are attributed to `Session`, which already owns turn boundaries.

```bash
git add lib/claude_code_md.rb lib/claude_code_md/session.rb spec/session_spec.rb docs/designs/design.8_5_2026.inline_responses.md
git commit -m "feat: watch loop composing inline responses into turns"
```

---

### Task 19: The `open` command

**Files:**
- Create: `lib/claude_code_md/runner.rb`
- Create: `spec/runner_spec.rb`, `spec/cli_spec.rb`
- Modify: `lib/claude_code_md/cli.rb`, `lib/claude_code_md.rb`, `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `Runner.new(target:, options:, env:) -> Runner` with `#path`, `#session_id`, `#cwd`, `#resume?`, `#call`; `ccmd open [TARGET]` invoked implicitly so `ccmd notes/chat.md` and `ccmd flaky-spec` both work; `Cli.implicit_open?(args) -> Boolean`.

`--new` against an existing file is an error rather than a silent new session: frontmatter is written once and never rewritten, so a fresh session id could not be recorded without breaking the append-only invariant.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/runner_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::Runner do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:env) { { "HOME" => @dir, "CCMD_GLOBAL_DIR" => File.join(@dir, "global") } }

  def runner(target, options = {})
    described_class.new(target: target,
                        options: { model: "opus", permission_mode: "auto" }.merge(options),
                        env: env)
  end

  it "resolves a slug into the global directory" do
    expect(runner("flaky-spec").path.to_s).to start_with(File.join(@dir, "global"))
  end

  it "generates a session id for a new conversation" do
    expect(runner("flaky-spec").session_id).to match(/\A[0-9a-f-]{36}\z/)
    expect(runner("flaky-spec")).not_to be_resume
  end

  it "reuses the session id recorded in an existing conversation" do
    path = File.join(@dir, "existing.md")
    File.write(path, "---\nsession_id: kept-123\ncwd: #{@dir}\nmodel: sonnet\n---\n\n")
    subject = runner(path)

    expect(subject.session_id).to eq("kept-123")
    expect(subject.cwd).to eq(@dir)
    expect(subject).to be_resume
  end

  it "prefers the repo root over the working directory for a new conversation" do
    FileUtils.mkdir_p(File.join(@dir, "repo", ".git"))
    FileUtils.mkdir_p(nested = File.join(@dir, "repo", "app"))

    expect(runner("x", cwd_override: nested).cwd).to eq(File.join(@dir, "repo"))
  end

  it "honours an explicit cwd" do
    expect(runner("x", cwd: "/tmp/elsewhere").cwd).to eq("/tmp/elsewhere")
  end

  it "refuses --new against an existing conversation" do
    path = File.join(@dir, "existing.md")
    File.write(path, "---\nsession_id: kept-123\n---\n\n")

    expect { runner(path, new: true).session_id }.to raise_error(Thor::Error, /already exists/)
  end
end
```

```ruby
# spec/cli_spec.rb
# frozen_string_literal: true

RSpec.describe ClaudeCodeMd::Cli do
  describe ".implicit_open?" do
    it "treats a path as an implicit open target" do
      expect(described_class.implicit_open?(["notes/chat.md"])).to be(true)
    end

    it "treats an unknown bare word as a slug to open" do
      expect(described_class.implicit_open?(["flaky-spec"])).to be(true)
    end

    it "leaves real commands alone" do
      expect(described_class.implicit_open?(["ls"])).to be(false)
      expect(described_class.implicit_open?(["setup"])).to be(false)
      expect(described_class.implicit_open?(["help"])).to be(false)
    end

    it "leaves flags alone" do
      expect(described_class.implicit_open?(["--version"])).to be(false)
    end

    it "leaves an empty invocation alone" do
      expect(described_class.implicit_open?([])).to be(false)
    end
  end

  describe "version" do
    it "prints the version" do
      expect { described_class.start(["version"]) }.to output("#{ClaudeCodeMd::VERSION}\n").to_stdout
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/runner_spec.rb spec/cli_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::Runner`.

- [ ] **Step 3: Implement the runner**

```ruby
# lib/claude_code_md/runner.rb
# frozen_string_literal: true

require "securerandom"

module ClaudeCodeMd
  # Assembles the object graph for `ccmd open`, so the CLI stays a thin
  # argument-parsing layer. Frontmatter wins over flags for a conversation that
  # already exists, which is what stops a reattach from silently changing its
  # model or working directory.
  class Runner
    def initialize(target:, options:, env: ENV)
      @target = target
      @options = options
      @env = env
    end

    def markers = @markers ||= Markers.from_env(@env)

    def path
      @path ||= Location.resolve(@target, dir: @options[:dir], shape: shape, env: @env)
    end

    def conversation = @conversation ||= ConversationFile.new(path)

    def resume?
      return @resume unless @resume.nil?

      @resume = conversation.exist? && !@options[:new]
    end

    def session_id
      @session_id ||= begin
        refuse_new_over_existing!
        resume? ? settings.fetch(:session_id) { SecureRandom.uuid } : SecureRandom.uuid
      end
    end

    def cwd
      @cwd ||= if resume?
                 settings.fetch(:cwd) { default_cwd }
               else
                 @options[:cwd] || default_cwd
               end
    end

    def call
      conversation.create(session_id: session_id, cwd: cwd, model: model,
                          permission_mode: permission_mode)
      process = build_process
      process.start(resume: resume?)
      install_interrupt_handler(process)
      build_session(process).run
    ensure
      process&.stop
    end

    private

    def settings = @settings ||= conversation.exist? ? conversation.frontmatter : {}
    def model = resume? ? settings.fetch(:model) { @options[:model] } : @options[:model]

    def permission_mode
      resume? ? settings.fetch(:permission_mode) { @options[:permission_mode] } : @options[:permission_mode]
    end

    def default_cwd
      base = @options[:cwd_override] || Dir.pwd
      Location.repo_root(base)&.to_s || base
    end

    def shape
      return :repo if @options[:repo]
      return :global if @options[:global]

      nil
    end

    def refuse_new_over_existing!
      return unless @options[:new] && conversation.exist?

      raise Thor::Error, "#{path} already exists; frontmatter is written once, so pass a new name instead"
    end

    def build_process
      ClaudeProcess.new(session_id: session_id, cwd: cwd, model: model,
                        permission_mode: permission_mode, markers: markers)
    end

    def build_session(process)
      trace = TraceFile.new(conversation.trace_path)
      Session.new(
        conversation: conversation, trace: trace, gate: SendGate.new(conversation.path),
        process: process,
        renderer: TranscriptRenderer.new(conversation: conversation, trace: trace,
                                         markers: markers, max_bytes: @options[:trace_max_bytes]),
        turn_state: TurnState.new,
        conversation_state: ConversationState.load(path: conversation.state_path,
                                                   blocks: conversation.blocks, markers: markers),
        markers: markers
      )
    end

    def install_interrupt_handler(process)
      Signal.trap("INT") do
        conversation.append_note("⏹ interrupted")
        process.stop
        exit(130)
      end
    end
  end
end
```

- [ ] **Step 4: Wire the command**

Replace the body of `ClaudeCodeMd::Cli` with:

```ruby
    extend ThorExt::Start

    map %w[-v --version] => :version

    desc "version", "Print the ccmd version"
    def version
      say ClaudeCodeMd::VERSION
    end

    desc "open [TARGET]", "Open or create a conversation and start watching it"
    option :cwd, type: :string, desc: "Directory CC runs in (default: the git repo root, else pwd)"
    option :model, type: :string, default: "opus", desc: "Model alias or full name"
    option :permission_mode, type: :string, default: "auto", desc: "CC permission mode"
    option :effort, type: :string, desc: "Reasoning effort"
    option :new, type: :boolean, default: false, desc: "Require a brand-new conversation file"
    option :dir, type: :string, desc: "Directory to resolve a slug in"
    option :repo, type: :boolean, desc: "Resolve the slug repo-relative"
    option :global, type: :boolean, desc: "Resolve the slug in the global directory"
    option :trace_max_bytes, type: :numeric, desc: "Cap each traced tool result"
    def open(target = nil)
      raise Thor::Error, "give a conversation file or a slug" if target.nil?

      Runner.new(target: target, options: options).call
    end

    # Injects the implicit `open` so `ccmd notes/chat.md` works without the verb.
    def self.start(given_args = ARGV, config = {})
      args = given_args.dup
      args.unshift("open") if implicit_open?(args)
      super(args, config)
    end

    def self.implicit_open?(args)
      first = args.first
      return false if first.nil? || first.start_with?("-")

      !all_commands.key?(first.tr("-", "_"))
    end

    def self.exit_on_failure? = true
```

Add `require_relative "claude_code_md/runner"` to `lib/claude_code_md.rb`, after the components it references.

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 6: Update the README and commit**

Replace the README's status blockquote with real usage: `ccmd notes/chat.md`, `ccmd flaky-spec`, the flag list, the two location environment variables, the inline-response markers with a short example, and the `CCMD_*` configuration table. Keep the note that in-file permission approvals are not implemented.

```bash
git add lib/claude_code_md.rb lib/claude_code_md/cli.rb lib/claude_code_md/runner.rb spec/runner_spec.rb spec/cli_spec.rb README.md
git commit -m "feat: ccmd open runs a conversation end to end"
```

---

### Task 20: The `ls`, `trace`, and `setup` commands

**Files:**
- Create: `lib/claude_code_md/editor_setup.rb`
- Create: `spec/editor_setup_spec.rb`
- Modify: `lib/claude_code_md/cli.rb`, `lib/claude_code_md.rb`, `README.md`
- Modify: `docs/designs/design.8_5_2026.ccmd_architecture.md`

**Interfaces:**
- Consumes: `ConversationIndex`, `Location`, `ConversationFile`.
- Produces: `EditorSetup.new(keybindings_path:, tasks_path:)` with `#keybinding_snippet`, `#task_snippet`, `#write_task -> :created | :present | :refused`, `#write_keybinding -> :created | :present | :refused`; commands `ccmd ls [--all]`, `ccmd trace TARGET`, `ccmd setup [--write]`.

Writing is opt-in and conservative. VSCode config is JSONC, and comments cannot survive a JSON round trip, so `--write` refuses any file containing them rather than eating them.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/editor_setup_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::EditorSetup do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:keybindings) { File.join(@dir, "keybindings.json") }
  let(:tasks) { File.join(@dir, ".vscode", "tasks.json") }
  let(:setup) { described_class.new(keybindings_path: keybindings, tasks_path: tasks) }

  it "offers snippets naming the cc-send task and cmd+enter" do
    expect(setup.task_snippet).to include("cc-send").and include("${file}.send")
    expect(setup.keybinding_snippet).to include("cmd+enter").and include("runCommands")
  end

  it "creates tasks.json when absent" do
    expect(setup.write_task).to eq(:created)
    expect(JSON.parse(File.read(tasks))["tasks"].first["label"]).to eq("cc-send")
  end

  it "leaves an existing cc-send task alone" do
    setup.write_task

    expect(setup.write_task).to eq(:present)
  end

  it "adds the task to a tasks.json that has others" do
    FileUtils.mkdir_p(File.dirname(tasks))
    File.write(tasks, JSON.generate("version" => "2.0.0", "tasks" => [{ "label" => "other" }]))
    setup.write_task

    expect(JSON.parse(File.read(tasks))["tasks"].map { |task| task["label"] }).to eq(%w[other cc-send])
  end

  it "creates keybindings.json when absent" do
    expect(setup.write_keybinding).to eq(:created)
    expect(JSON.parse(File.read(keybindings)).first["key"]).to eq("cmd+enter")
  end

  it "refuses to rewrite a keybindings file containing comments" do
    File.write(keybindings, "// my keybindings\n[]\n")

    expect(setup.write_keybinding).to eq(:refused)
    expect(File.read(keybindings)).to eq("// my keybindings\n[]\n")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/editor_setup_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::EditorSetup`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/editor_setup.rb
# frozen_string_literal: true

require "json"
require "pathname"

module ClaudeCodeMd
  # Editor wiring for the send gate. VSCode config is JSONC and comments cannot
  # survive a JSON round trip, so writing is opt-in and refuses any file it
  # cannot rewrite faithfully.
  class EditorSetup
    TASK = {
      "label" => "cc-send",
      "type" => "shell",
      "command" => "touch '${file}.send'",
      "presentation" => { "reveal" => "never" },
      "problemMatcher" => []
    }.freeze

    KEYBINDING = {
      "key" => "cmd+enter",
      "when" => "editorTextFocus && resourceExtname == .md",
      "command" => "runCommands",
      "args" => { "commands" => ["workbench.action.files.save",
                                 { "command" => "workbench.action.tasks.runTask", "args" => "cc-send" }] }
    }.freeze

    def initialize(keybindings_path:, tasks_path:)
      @keybindings_path = Pathname.new(keybindings_path)
      @tasks_path = Pathname.new(tasks_path)
    end

    def task_snippet = JSON.pretty_generate(TASK)
    def keybinding_snippet = JSON.pretty_generate(KEYBINDING)

    # @return [Symbol] :created, :present, or :refused
    def write_task
      write(@tasks_path, default: { "version" => "2.0.0", "tasks" => [] }) do |config|
        tasks = config["tasks"] ||= []
        next :present if tasks.any? { |task| task["label"] == TASK["label"] }

        tasks << TASK.dup
        :created
      end
    end

    # @return [Symbol] :created, :present, or :refused
    def write_keybinding
      write(@keybindings_path, default: []) do |config|
        next :present if config.any? { |binding| binding["key"] == KEYBINDING["key"] }

        config << KEYBINDING.dup
        :created
      end
    end

    private

    def write(path, default:)
      config = default
      if path.exist?
        raw = path.read
        return :refused if comments?(raw)

        config = JSON.parse(raw) unless raw.strip.empty?
      end

      outcome = yield(config)
      return outcome if outcome == :present

      path.dirname.mkpath
      path.write("#{JSON.pretty_generate(config)}\n")
      outcome
    end

    # Deliberately blunt: any // or /* anywhere means hands off.
    def comments?(raw) = raw.include?("//") || raw.include?("/*")
  end
end
```

- [ ] **Step 4: Wire the commands**

Add to `ClaudeCodeMd::Cli`:

```ruby
    desc "ls", "List conversations with their session id and last activity"
    option :all, type: :boolean, default: false, desc: "Scan both the repo and global directories"
    def ls
      entries = ConversationIndex.entries(all: options[:all])
      return say("no conversations yet") if entries.empty?

      entries.each do |entry|
        say format("%-52s %s  %s", entry[:path].basename,
                   entry[:updated_at].strftime("%-m/%-d/%Y %H:%M"), entry[:session_id])
      end
    end

    desc "trace TARGET", "Print the path of a conversation's trace file"
    def trace(target)
      say ConversationFile.new(Location.resolve(target)).trace_path.to_s
    end

    desc "setup", "Show, or with --write install, the cmd+enter editor wiring"
    option :write, type: :boolean, default: false, desc: "Write the files instead of printing"
    option :keybindings, type: :string, desc: "Path to keybindings.json"
    def setup
      editor = EditorSetup.new(keybindings_path: options[:keybindings] || default_keybindings_path,
                               tasks_path: File.join(Dir.pwd, ".vscode", "tasks.json"))
      return print_setup(editor) unless options[:write]

      say "tasks.json: #{editor.write_task}"
      say "keybindings.json: #{editor.write_keybinding}"
    end
```

and these private helpers:

```ruby
    private

    def default_keybindings_path
      File.join(Dir.home, "Library", "Application Support", "Code", "User", "keybindings.json")
    end

    def print_setup(editor)
      say "Add to keybindings.json:"
      say editor.keybinding_snippet
      say "\nAdd to .vscode/tasks.json:"
      say editor.task_snippet
      say "\nRe-run with --write to install them."
    end
```

Add `require_relative "claude_code_md/editor_setup"` to `lib/claude_code_md.rb`.

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 6: Correct the design, update the README, and commit**

In `docs/designs/design.8_5_2026.ccmd_architecture.md`, change "Editor wiring, which is one-time and what `ccmd setup` writes" to say that `ccmd setup` prints the wiring by default, installs it with `--write`, and refuses files containing comments. Add the same to the README.

```bash
git add lib/claude_code_md.rb lib/claude_code_md/cli.rb lib/claude_code_md/editor_setup.rb spec/editor_setup_spec.rb docs/designs/design.8_5_2026.ccmd_architecture.md README.md
git commit -m "feat: ls, trace, and setup commands"
```

---

## Manual Verification

Automated specs never touch the real CC, so run this once after Task 20:

- [ ] `ccmd setup --write` in a scratch directory, then confirm cmd+enter creates a `.send` file
- [ ] `ccmd scratch-test` inside a git repo, then confirm the file lands under `docs/agent-local/conversations`
- [ ] Type a question, press cmd+enter, and watch the reply stream in without the tab closing
- [ ] Edit a line higher up in the file while a reply streams, then confirm the reply still appends at the end and your edit survives
- [ ] Send a second turn while the first is still streaming, then confirm it runs after the first rather than interleaving
- [ ] Ask CC for a decision list, then confirm each item gets an options line
- [ ] Answer two of three questions in place, press cmd+enter, and confirm only those two are quoted back and acknowledged
- [ ] Press cmd+enter again without changing anything, and confirm nothing is sent
- [ ] Correct an answer you already sent, and confirm it arrives as a follow-up
- [ ] Reword a line CC wrote, and confirm it arrives as a diff
- [ ] Delete a line CC wrote, and confirm it is reported in the terminal and not sent
- [ ] Ask for something that uses tools, then confirm the conversation stays prose-only and the trace holds full results
- [ ] Delete the `.state.json` mid-conversation, then confirm the next send produces no backlog
- [ ] Kill the child with `pkill -f 'claude -p'`, then confirm the next turn resumes the same session
- [ ] Ctrl+C, then confirm the conversation gets its interrupted note

## Self-Review Notes

**Spec coverage.** Base design: Conversation Location to Task 13, Trace File to Tasks 11 and 16, Send Sidecar to Task 12, CC Invocation to Task 15, the Components table to Tasks 10–18, CLI Surface to Tasks 19–20, Error Handling to Tasks 16, 18, and the manual list. Inline-responses design: Marker Vocabulary to Task 3, Block Snapshots and The State File to Task 9, Diff Rules and Pairing to Task 6, What Gets Sent to Task 7, Resolution Without Rewriting to Tasks 9 and 18, Teaching CC The Vocabulary to Task 15, options lines to Task 16, Configuration to Task 3, every Edge Cases row to a spec in Tasks 3, 5, 6, 9, or 18.

**Type consistency.** `Markers` is passed as `markers:` everywhere. `ConversationState` is `conversation_state:` in `Session` while `TurnState` is `turn_state:`, so the two never collide. `InlineResponses::Response` field names are identical in Tasks 6, 7, 9, and 16. `Session#tick` returns one of `:idle`, `:sent`, `:finished`, `:dead` in every reference.

**Deliberate gaps**, each recorded in Divergences From The Designs and corrected in the design text by the task that introduces them: options lines belong to `ProseStream`, state advance belongs to `Session`, `TurnState` has two states, `ccmd setup` prints by default, `ClaudeProcess#interrupt` does not exist, and `consumed` is keyed by both hashes.

**Known risk.** The thinking-delta shape is the one thing no fixture may confirm. Task 1 Step 4 makes the implementer record what CC actually emits, and Task 8 Step 4 tells them to match the fixture rather than the guess written here.
