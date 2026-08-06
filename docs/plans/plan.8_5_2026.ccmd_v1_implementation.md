# ccmd v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ccmd` so a markdown file becomes a working conversation with CC — you type, press cmd+enter, and the reply streams into the same file.

**Architecture:** A long-lived `claude -p` child process is fed one JSON line per turn over stdin. A reader thread decodes its stdout onto a queue; the main thread interleaves draining that queue with polling for a send signal. Prose appends to the conversation file, everything else to a sibling trace file. All conversation writes are appends, so the user editing the file mid-turn never loses work.

**Tech Stack:** Ruby 3.4+, Thor, `omg-thor-ext`, RSpec, RuboCop. Everything else is standard library.

## Global Constraints

- Ruby `>= 3.4.0`; RuboCop `TargetRubyVersion: 3.4`.
- Runtime dependencies are exactly `thor ~> 1.5` and `omg-thor-ext ~> 0.1`. Everything else must be standard library. Do not add a gem without changing this line.
- `bundle exec rake` (RSpec + RuboCop) must pass before every commit.
- Strings are double-quoted; every file starts with `# frozen_string_literal: true`.
- Every write to a conversation file uses append mode. Never rewrite a conversation file after creation.
- No spec may spawn the real `claude` binary. Subprocess behavior is tested against the fake executable built in Task 9.
- In prose and docs, write `CC`, not "Claude Code".
- Document classes and public methods. Omit docs where they add nothing. Put a blank commented line between a method description and any `@param`. Omit `@return [void]`.
- Namespace is `ClaudeCodeMd`. Files live in `lib/claude_code_md/`, specs mirror them in `spec/`.

---

### Task 1: Record protocol fixtures

Every later task's tests depend on real CC output rather than a guess at its shape. Capture it once, commit it, and never call the network in a spec again.

**Files:**
- Create: `spec/fixtures/README.md`
- Create: `spec/fixtures/text_only.jsonl`
- Create: `spec/fixtures/with_tools.jsonl`
- Create: `spec/fixtures/with_thinking.jsonl`

**Interfaces:**
- Consumes: nothing.
- Produces: three JSONL fixture files, each one complete turn of `claude` stdout, ending in a `result` line.

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

- [ ] **Step 4: Verify each fixture is complete and note the delta shapes**

```bash
cd spec/fixtures
for f in *.jsonl; do
  echo "== $f"
  jq -r 'select(.type=="result") | "result: \(.subtype) is_error=\(.is_error)"' "$f"
  jq -r 'select(.type=="stream_event") | .event.delta.type' "$f" | sort -u
done
```

Expected: each file prints exactly one `result:` line, and the delta types printed are the ones later tasks must handle. **If `with_thinking.jsonl` shows no thinking delta type, record that in `spec/fixtures/README.md` and skip the thinking assertions in Task 10 rather than inventing a shape.**

- [ ] **Step 5: Document the fixtures**

Write `spec/fixtures/README.md` naming each file, the command that produced it, the `claude` version (`claude --version`), and the delta types observed in Step 4.

- [ ] **Step 6: Commit**

```bash
git add spec/fixtures
git commit -m "test: record CC stream-json fixtures"
```

---

### Task 2: Frontmatter and turn markers

**Files:**
- Create: `lib/claude_code_md/frontmatter.rb`
- Create: `lib/claude_code_md/turn_marker.rb`
- Create: `spec/frontmatter_spec.rb`
- Create: `spec/turn_marker_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Frontmatter.parse(String) -> Hash` with symbol keys, `{}` when absent.
  - `Frontmatter.render(Hash) -> String` including both `---` delimiters and a trailing blank line.
  - `TurnMarker.render(turn:, role:, time:) -> String` — comment line, heading line, blank line.
  - `TurnMarker.scan(String) -> Array<[line_index, turn_number, role_symbol]>`.
  - `TurnMarker.last_turn_number(String) -> Integer`, `0` when there are no markers.

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

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rake`
Expected: all examples pass, no RuboCop offenses.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/frontmatter.rb lib/claude_code_md/turn_marker.rb spec/frontmatter_spec.rb spec/turn_marker_spec.rb
git commit -m "feat: parse conversation frontmatter and turn markers"
```

---

### Task 3: Delta extraction

**Files:**
- Create: `lib/claude_code_md/delta_extractor.rb`
- Create: `spec/delta_extractor_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `TurnMarker.scan` from Task 2.
- Produces: `DeltaExtractor.call(String) -> String` (the user's new text, stripped) and `DeltaExtractor::SEND_TOKEN == "/send"`.

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

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/delta_extractor_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::DeltaExtractor`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/delta_extractor.rb
# frozen_string_literal: true

require_relative "turn_marker"

module ClaudeCodeMd
  # Pulls the text the user just typed out of a conversation file: everything
  # after the final user marker's heading, minus the send token.
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
git commit -m "feat: extract the pending user turn from a conversation"
```

---

### Task 4: Event codec

**Files:**
- Create: `lib/claude_code_md/event_codec.rb`
- Create: `spec/event_codec_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: fixtures from Task 1.
- Produces:
  - `EventCodec.encode_user(String, session_id:) -> String` (one JSON line, no newline).
  - `EventCodec.decode(String) -> EventCodec::Event | nil` (`nil` on unparseable input).
  - `EventCodec::Event` with readers `type`, `subtype`, `raw` and methods `text_delta`, `thinking_delta`, `tool_uses`, `tool_results`, `session_id`, `result?`, `error?`, `duration_ms`, `total_cost_usd`, `num_turns`.

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

    it "escapes newlines and quotes in prose" do
      line = described_class.encode_user("line one\n\n\"quoted\"", session_id: "abc-123")

      expect(line).not_to include("\n")
      expect(JSON.parse(line).dig("message", "content", 0, "text")).to eq("line one\n\n\"quoted\"")
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
  # Translates between CC's stream-json protocol and plain Ruby values. Pure:
  # it touches neither the filesystem nor the child process.
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

    # @param text [String] the user's prose, which may contain newlines
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
Expected: all pass. If the thinking delta type in `spec/fixtures/README.md` differs from `thinking_delta`, change the string in `thinking_delta` to match the fixture and note it in a comment.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/event_codec.rb spec/event_codec_spec.rb
git commit -m "feat: encode and decode the CC stream-json protocol"
```

---

### Task 5: Conversation file

**Files:**
- Create: `lib/claude_code_md/conversation_file.rb`
- Create: `spec/conversation_file_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `Frontmatter`, `TurnMarker`, `DeltaExtractor`.
- Produces: `ConversationFile.new(path)` with `#path`, `#exist?`, `#create(session_id:, cwd:, model:, permission_mode:, now:)`, `#frontmatter`, `#read`, `#pending_text`, `#open_turn(role:, now:)`, `#append(text)`, `#append_note(text)`, `#trace_path`.

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

  it "derives the trace path from the conversation path" do
    expect(file.trace_path.to_s).to eq(File.join(@dir, "nested", "conversation.trace.md"))
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
    def trace_path = path.sub_ext(".trace.md")

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

### Task 6: Trace file

**Files:**
- Create: `lib/claude_code_md/trace_file.rb`
- Create: `spec/trace_file_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `TraceFile.new(path)` with `#start_turn(turn:, now:)`, `#append(text)`, `#tool_use(name:, input:)`, `#tool_result(content:, max_bytes:)`, `#finish_turn(duration_ms:, num_turns:, total_cost_usd:)`, `#anchor(turn)`.

Formatting decisions live here so `TranscriptRenderer` stays about routing.

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

require "pathname"

module ClaudeCodeMd
  # The sibling document holding thinking and tool activity. Tool results are
  # recorded in full by default: the trace is built from output CC already
  # streamed, is never read back into a session, and so costs no tokens.
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

    def tool_use(name:, input:)
      append("### `#{name}`\n\n```json\n#{JSON.pretty_generate(input)}\n```\n\n")
    end

    # @param max_bytes [Integer, nil] nil records the whole result
    def tool_result(content:, max_bytes: nil)
      body = content.to_s
      summary = "Result — #{body.lines.size} #{body.lines.size == 1 ? "line" : "lines"}"
      if max_bytes && body.bytesize > max_bytes
        body = "#{body.byteslice(0, max_bytes)}\n… truncated at #{max_bytes} bytes"
      end

      append("<details><summary>#{summary}</summary>\n\n```\n#{body}\n```\n\n</details>\n\n")
    end

    def finish_turn(duration_ms:, num_turns:, total_cost_usd: nil)
      parts = ["Duration #{format("%.1f", duration_ms.to_i / 1000.0)}s",
               "#{num_turns} #{num_turns == 1 ? "turn" : "turns"}"]
      parts << format("$%.4f", total_cost_usd) if total_cost_usd

      append("#{parts.join(" · ")}\n\n")
    end
  end
end
```

Add `require "json"` at the top of the file and `require_relative "claude_code_md/trace_file"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/trace_file.rb spec/trace_file_spec.rb
git commit -m "feat: trace file for thinking and tool activity"
```

---

### Task 7: Send gate

**Files:**
- Create: `lib/claude_code_md/send_gate.rb`
- Create: `spec/send_gate_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `DeltaExtractor::SEND_TOKEN`.
- Produces: `SendGate.new(conversation_path)` with `#poll -> :sidecar | :token | nil` and `#sidecar_path`.

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
  #
  # A token-triggered send keeps firing until the caller appends something after
  # it, so callers must open the CC turn before polling again.
  class SendGate
    def initialize(conversation_path)
      @conversation = Pathname.new(conversation_path)
      @sidecar = Pathname.new("#{conversation_path}.send")
    end

    attr_reader :sidecar_path

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

Remove the stray `attr_reader :sidecar_path` line if RuboCop flags the duplicate definition — the endless method below it is the one to keep.

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

### Task 8: Location resolution

**Files:**
- Create: `lib/claude_code_md/location.rb`
- Create: `spec/location_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Location.resolve(target, dir:, shape:, env:, cwd:, now:) -> Pathname` and `Location.directories(env:, cwd:) -> {repo: Pathname|nil, global: Pathname}`.

Resolution order and defaults are specified in the design's Conversation Location section. Implement exactly that table.

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

    expect(result.to_s).to eq(
      File.join(@dir, "trunk/docs/conversations", "conversation.8_5_2026.flaky_spec.md")
    )
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
  # given; a bare slug is resolved inside either a repo-relative or a global
  # directory, both configurable.
  module Location
    DEFAULT_REPO_SUBDIR = "docs/agent-local/conversations"
    DEFAULT_GLOBAL_SUBPATH = "trunk/docs/conversations"

    # @param target [String] a path or a slug
    # @param dir [String, nil] explicit directory, wins over every other source
    # @param shape [Symbol, nil] :repo or :global, forced by flag
    def self.resolve(target, dir: nil, shape: nil, env: ENV, cwd: Dir.pwd, now: Time.now)
      return Pathname.new(cwd).join(target).cleanpath if path_like?(target)

      base = dir ? Pathname.new(cwd).join(dir) : directory_for(shape, env: env, cwd: cwd)
      base.join(filename_for(target, now))
    end

    # @return [Hash] :repo may be nil when cwd is not inside a repository
    def self.directories(env: ENV, cwd: Dir.pwd)
      root = repo_root(cwd)
      { repo: root&.join(env.fetch("CCMD_REPO_SUBDIR", DEFAULT_REPO_SUBDIR)),
        global: global_directory(env) }
    end

    def self.path_like?(target) = target.include?("/") || target.end_with?(".md")

    def self.directory_for(shape, env:, cwd:)
      dirs = directories(env: env, cwd: cwd)
      shape ||= (env["CCMD_LOCATION"]&.to_sym || (dirs[:repo] ? :repo : :global))

      shape == :repo && dirs[:repo] ? dirs[:repo] : dirs[:global]
    end

    def self.global_directory(env)
      configured = env["CCMD_GLOBAL_DIR"]
      return Pathname.new(configured) if configured

      Pathname.new(env.fetch("HOME")).join(DEFAULT_GLOBAL_SUBPATH)
    end

    def self.repo_root(cwd)
      Pathname.new(cwd).expand_path.ascend { |dir| return dir if dir.join(".git").exist? }
      nil
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

### Task 9: Claude process

**Files:**
- Create: `lib/claude_code_md/claude_process.rb`
- Create: `spec/claude_process_spec.rb`
- Create: `spec/support/fake_claude.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `EventCodec`.
- Produces: `ClaudeProcess.new(session_id:, cwd:, model:, permission_mode:, executable:)` with `#start(resume:)`, `#send_user(text)`, `#events` (a `Thread::Queue` yielding `EventCodec::Event` and the `:eof` symbol), `#alive?`, `#stop`, `#command(resume:)`.

`#interrupt` is deliberately out of scope here: the control-protocol field shapes are unverified, so Task 12 stops the child instead and resumes. See the design's Deferred section.

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
File.write(ENV["FAKE_CLAUDE_ARGV"], ARGV.join(" ")) if ENV["FAKE_CLAUDE_ARGV"]
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

  def process(cwd: @dir)
    described_class.new(session_id: "abc-123", cwd: cwd, model: "opus",
                        permission_mode: "auto", executable: fake)
  end

  it "builds the verified invocation" do
    command = process.command(resume: false)

    expect(command).to include("-p", "--verbose", "--input-format", "stream-json",
                               "--output-format", "stream-json",
                               "--include-partial-messages",
                               "--session-id", "abc-123",
                               "--model", "opus",
                               "--permission-mode", "auto")
    expect(command).not_to include("--resume")
  end

  it "swaps session-id for resume when resuming" do
    command = process.command(resume: true)

    expect(command).to include("--resume", "abc-123")
    expect(command).not_to include("--session-id")
  end

  it "streams decoded events for a turn and terminates with a result" do
    subject = process
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
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
    subject.events.pop until subject.events.empty? && File.exist?(probe)

    expect(File.read(probe)).to eq(target)
    subject.stop
  ensure
    ENV.delete("FAKE_CLAUDE_FIXTURE")
    ENV.delete("FAKE_CLAUDE_CWD")
  end

  it "pushes :eof when the child exits" do
    ENV["FAKE_CLAUDE_FIXTURE"] = fixture
    subject = process
    subject.start
    subject.stop

    queue = subject.events
    queue.pop until queue.empty?

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

    def initialize(session_id:, cwd:, model:, permission_mode:, executable: "claude")
      @session_id = session_id
      @cwd = cwd.to_s
      @model = model
      @permission_mode = permission_mode
      @executable = executable
      @events = Thread::Queue.new
    end

    # @param resume [Boolean] true attaches to an existing session instead of declaring a new id
    def command(resume: false)
      session_flags = resume ? ["--resume", @session_id] : ["--session-id", @session_id]

      [@executable, *STREAM_FLAGS, *session_flags,
       "--model", @model, "--permission-mode", @permission_mode]
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
      @stdin&.close unless @stdin&.closed?
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
Expected: all pass. If a spec hangs, the reader thread is not reaching `:eof` — check that `stop` closes stdin before joining.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/claude_process.rb spec/claude_process_spec.rb spec/support/fake_claude.rb
git commit -m "feat: supervise the long-lived claude child process"
```

---

### Task 10: Transcript renderer

**Files:**
- Create: `lib/claude_code_md/transcript_renderer.rb`
- Create: `spec/transcript_renderer_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: `ConversationFile`, `TraceFile`, `EventCodec::Event`.
- Produces: `TranscriptRenderer.new(conversation:, trace:, max_bytes:)` with `#begin_turn(now:)`, `#handle(event, now:) -> :continue | :finished`.

`#handle` owns the `<details>` state for thinking: open the block on the first thinking delta, close it when prose or a tool arrives, or at turn end.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/transcript_renderer_spec.rb
# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeCodeMd::TranscriptRenderer do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:now) { Time.new(2026, 8, 5, 14, 33, 0) }
  let(:conversation) { ClaudeCodeMd::ConversationFile.new(File.join(@dir, "c.md")) }
  let(:trace) { ClaudeCodeMd::TraceFile.new(File.join(@dir, "c.trace.md")) }
  let(:renderer) { described_class.new(conversation: conversation, trace: trace) }

  def event(hash) = ClaudeCodeMd::EventCodec::Event.new(type: hash["type"], subtype: hash["subtype"], raw: hash)

  def text_event(text)
    event("type" => "stream_event",
          "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => text } })
  end

  before do
    conversation.create(session_id: "abc-123", cwd: @dir, model: "opus", permission_mode: "auto", now: now)
    renderer.begin_turn(now: now)
  end

  it "opens a CC turn in the conversation and a turn in the trace" do
    expect(conversation.read).to include("<!-- ccmd:turn=1 role=cc -->")
    expect(trace.read).to include("## Turn 1 — 14:33")
  end

  it "streams prose into the conversation only" do
    renderer.handle(text_event("Because the "), now: now)
    renderer.handle(text_event("factory memoizes."), now: now)

    expect(conversation.read).to end_with("Because the factory memoizes.")
    expect(trace.read).not_to include("factory")
  end

  it "routes tool activity to the trace only" do
    renderer.handle(event("type" => "assistant", "message" => {
                            "content" => [{ "type" => "tool_use", "name" => "Bash",
                                            "input" => { "command" => "echo hi" } }]
                          }), now: now)
    renderer.handle(event("type" => "user", "message" => {
                            "content" => [{ "type" => "tool_result", "content" => "hi\n" }]
                          }), now: now)

    expect(trace.read).to include("### `Bash`").and include("echo hi").and include("hi")
    expect(conversation.read).not_to include("echo hi")
  end

  it "closes the turn on a result, linking the trace and opening the next user turn" do
    outcome = renderer.handle(event("type" => "result", "subtype" => "success", "is_error" => false,
                                    "duration_ms" => 13_068, "num_turns" => 2), now: now)

    expect(outcome).to eq(:finished)
    expect(conversation.read).to include("[trace](c.trace.md#turn-1)")
    expect(conversation.read).to end_with("<!-- ccmd:turn=2 role=me -->\n## Me — 14:33\n\n")
    expect(trace.read).to include("Duration 13.1s · 2 turns")
  end

  it "records an errored result in the conversation so the reason is visible" do
    renderer.handle(event("type" => "result", "subtype" => "error_during_execution",
                          "is_error" => true, "duration_ms" => 10, "num_turns" => 1), now: now)

    expect(conversation.read).to include("> ⚠️ error_during_execution")
  end

  it "ignores events it has no sink for" do
    expect(renderer.handle(event("type" => "rate_limit_event"), now: now)).to eq(:continue)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/transcript_renderer_spec.rb`
Expected: FAIL with `uninitialized constant ClaudeCodeMd::TranscriptRenderer`.

- [ ] **Step 3: Implement**

```ruby
# lib/claude_code_md/transcript_renderer.rb
# frozen_string_literal: true

module ClaudeCodeMd
  # Routes decoded events to the two sinks: prose to the conversation, thinking
  # and tool activity to the trace. Nothing else writes to either file.
  class TranscriptRenderer
    def initialize(conversation:, trace:, max_bytes: nil)
      @conversation = conversation
      @trace = trace
      @max_bytes = max_bytes
      @thinking_open = false
    end

    def begin_turn(now: Time.now)
      @turn = TurnMarker.last_turn_number(@conversation.read)
      @conversation.open_turn(role: :cc, now: now)
      @trace.start_turn(turn: @turn, now: now)
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
      render_prose(event)
      render_tools(event)
      :continue
    end

    private

    def render_prose(event)
      text = event.text_delta
      @conversation.append(text) if text
    end

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

    def finish(event, now:)
      close_thinking
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

Add `require_relative "claude_code_md/transcript_renderer"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/transcript_renderer.rb spec/transcript_renderer_spec.rb
git commit -m "feat: route prose to the conversation and everything else to the trace"
```

---

### Task 11: Turn state

**Files:**
- Create: `lib/claude_code_md/turn_state.rb`
- Create: `spec/turn_state_spec.rb`
- Modify: `lib/claude_code_md.rb`
- Modify: `docs/designs/design.8_5_2026.ccmd_architecture.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `TurnState.new` with `#idle?`, `#streaming?`, `#submit(text) -> :sent | :queued`, `#finish -> String | nil`.

The design describes `idle → streaming → tool-wait → done`. Nothing behaves differently during tool-wait — the renderer handles tool events identically whether or not prose has started — so the implementation collapses it to `idle → streaming`. Step 5 corrects the design text rather than leaving the two out of sync.

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

  it "hands back queued text in order as turns finish" do
    state.submit("first")
    state.submit("second")
    state.submit("third")

    expect(state.finish).to eq("second")
    expect(state).to be_streaming
    expect(state.finish).to eq("third")
    expect(state.finish).to be_nil
    expect(state).to be_idle
  end

  it "ignores empty submissions" do
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
  # Tracks whether a turn is in flight and holds anything the user sends while
  # one is. Collapsed to idle and streaming: no behavior differs during a tool
  # call, so a separate state would carry no information.
  class TurnState
    def initialize
      @streaming = false
      @queued = []
    end

    def idle? = !@streaming
    def streaming? = @streaming

    # @return [Symbol, nil] :sent when the caller should transmit now, :queued
    #   when it is held for later, nil when there was nothing to send
    def submit(text)
      return nil if text.nil? || text.strip.empty?

      if @streaming
        @queued << text
        :queued
      else
        @streaming = true
        :sent
      end
    end

    # @return [String, nil] the next queued turn to transmit, or nil when idle
    def finish
      next_text = @queued.shift
      @streaming = !next_text.nil?
      next_text
    end
  end
end
```

Add `require_relative "claude_code_md/turn_state"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Correct the design, then commit**

In `docs/designs/design.8_5_2026.ccmd_architecture.md`, change the `TurnState` row of the Components table from `idle → streaming → tool-wait → done; queue turns arriving mid-flight` to `idle → streaming; queue turns arriving mid-flight`, and change the Concurrency section's mention of the same four states to two. Then:

```bash
git add lib/claude_code_md.rb lib/claude_code_md/turn_state.rb spec/turn_state_spec.rb docs/designs/design.8_5_2026.ccmd_architecture.md
git commit -m "feat: track in-flight turns and queue mid-turn submissions"
```

---

### Task 12: Session orchestrator

**Files:**
- Create: `lib/claude_code_md/session.rb`
- Create: `spec/session_spec.rb`
- Modify: `lib/claude_code_md.rb`

**Interfaces:**
- Consumes: every component from Tasks 5–11.
- Produces: `Session.new(conversation:, trace:, gate:, process:, renderer:, state:, poll_interval:)` with `#run(iterations: nil)` and `#tick -> :idle | :sent | :finished | :dead`.

`#run(iterations:)` exists so specs can drive a bounded number of loop passes instead of racing a background thread.

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
  let(:conversation) { ClaudeCodeMd::ConversationFile.new(path) }
  let(:trace) { ClaudeCodeMd::TraceFile.new(conversation.trace_path) }
  let(:gate) { ClaudeCodeMd::SendGate.new(path) }
  let(:process) do
    ClaudeCodeMd::ClaudeProcess.new(session_id: "abc-123", cwd: @dir, model: "opus",
                                    permission_mode: "auto",
                                    executable: File.expand_path("support/fake_claude.rb", __dir__))
  end
  let(:session) do
    described_class.new(conversation: conversation, trace: trace, gate: gate, process: process,
                        renderer: ClaudeCodeMd::TranscriptRenderer.new(conversation: conversation, trace: trace),
                        state: ClaudeCodeMd::TurnState.new, poll_interval: 0)
  end

  before do
    ENV["FAKE_CLAUDE_FIXTURE"] = File.expand_path("fixtures/text_only.jsonl", __dir__)
    conversation.create(session_id: "abc-123", cwd: @dir, model: "opus", permission_mode: "auto", now: now)
    process.start
  end

  after do
    process.stop
    ENV.delete("FAKE_CLAUDE_FIXTURE")
  end

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

  it "does not re-fire on a token send once the CC turn is open" do
    conversation.append("a question\n\n/send\n")

    expect(session.tick).to eq(:sent)
    expect(session.tick).not_to eq(:sent)
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

module ClaudeCodeMd
  # The watch loop. Interleaves polling for a send signal with draining the
  # events the reader thread has queued, and does every file write itself so
  # nothing else races on the conversation.
  class Session
    DEFAULT_POLL_INTERVAL = 0.15

    def initialize(conversation:, trace:, gate:, process:, renderer:, state:,
                   poll_interval: DEFAULT_POLL_INTERVAL)
      @conversation = conversation
      @trace = trace
      @gate = gate
      @process = process
      @renderer = renderer
      @state = state
      @poll_interval = poll_interval
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

      text = @conversation.pending_text
      return nil if @state.submit(text) != :sent

      # Open the CC turn before returning, so a token send stops matching.
      @renderer.begin_turn
      @process.send_user(text)
      :sent
    end

    def drain_events
      outcome = :idle
      until @process.events.empty?
        event = @process.events.pop
        return :dead if event == :eof

        outcome = :finished if @renderer.handle(event) == :finished
        send_queued_turn if outcome == :finished
      end
      outcome
    end

    def send_queued_turn
      queued = @state.finish
      return unless queued

      @renderer.begin_turn
      @process.send_user(queued)
    end
  end
end
```

Add `require_relative "claude_code_md/session"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/session.rb spec/session_spec.rb
git commit -m "feat: watch loop wiring the gate, child, and renderer together"
```

---

### Task 13: The `open` command

**Files:**
- Modify: `lib/claude_code_md/cli.rb`
- Create: `spec/cli_spec.rb`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Location`, `ConversationFile`, `TraceFile`, `SendGate`, `ClaudeProcess`, `TranscriptRenderer`, `TurnState`, `Session`.
- Produces: `ccmd open [TARGET]`, invoked implicitly so `ccmd notes/chat.md` and `ccmd flaky-spec` both work. Flags: `--cwd`, `--model`, `--permission-mode`, `--effort`, `--new`, `--dir`, `--repo`, `--global`, `--trace-max-bytes`.

- [ ] **Step 1: Write the failing spec**

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

    it "leaves a real command alone" do
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

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/cli_spec.rb`
Expected: FAIL with `undefined method 'implicit_open?'`.

- [ ] **Step 3: Implement**

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
    option :new, type: :boolean, default: false, desc: "Start a new session even if the file exists"
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

Create the runner that turns options into wired objects, in the same file below the class:

```ruby
  # Assembles the object graph for `ccmd open`. Kept out of Cli so the command
  # stays a thin argument-parsing layer.
  class Runner
    def initialize(target:, options:)
      @target = target
      @options = options
    end

    def call
      conversation = ConversationFile.new(path)
      conversation.create(session_id: session_id, cwd: cwd, model: @options[:model],
                          permission_mode: @options[:permission_mode])
      trace = TraceFile.new(conversation.trace_path)
      process = build_process(conversation)
      process.start(resume: !@options[:new] && resume?(conversation))
      install_interrupt_handler(process, conversation)
      build_session(conversation, trace, process).run
    ensure
      process&.stop
    end

    private

    def path
      @path ||= Location.resolve(@target, dir: @options[:dir], shape: shape)
    end

    def shape
      return :repo if @options[:repo]
      return :global if @options[:global]

      nil
    end

    def cwd
      @options[:cwd] || Location.repo_root(Dir.pwd)&.to_s || Dir.pwd
    end

    def session_id
      @session_id ||= existing_session_id || SecureRandom.uuid
    end

    def existing_session_id
      return nil if @options[:new]

      ConversationFile.new(path).then { |file| file.exist? ? file.frontmatter[:session_id] : nil }
    end

    def resume?(conversation) = !conversation.frontmatter[:session_id].nil? && !@resumed_fresh

    def build_process(conversation)
      settings = conversation.frontmatter
      @resumed_fresh = false
      ClaudeProcess.new(session_id: settings.fetch(:session_id, session_id),
                        cwd: settings.fetch(:cwd, cwd),
                        model: settings.fetch(:model, @options[:model]),
                        permission_mode: settings.fetch(:permission_mode, @options[:permission_mode]))
    end

    def build_session(conversation, trace, process)
      Session.new(conversation: conversation, trace: trace,
                  gate: SendGate.new(conversation.path),
                  process: process,
                  renderer: TranscriptRenderer.new(conversation: conversation, trace: trace,
                                                   max_bytes: @options[:trace_max_bytes]),
                  state: TurnState.new)
    end

    def install_interrupt_handler(process, conversation)
      Signal.trap("INT") do
        conversation.append_note("⏹ interrupted")
        process.stop
        exit(130)
      end
    end
  end
```

Add `require "securerandom"` and `require_relative "location"` to the top of `cli.rb`, plus `require_relative "runner"` style requires as needed by however the file is split. **A newly created file has just been given a session id in its frontmatter, so `resume?` must be false on that first start** — the file did not exist before `create`, so capture `conversation.exist?` before calling `create` and pass that boolean into `start(resume:)`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Update the README and commit**

Replace the README's status blockquote with real usage: `ccmd notes/chat.md`, `ccmd flaky-spec`, the flag list, and the two location environment variables. Keep the note that in-file approvals are not implemented.

```bash
git add lib/claude_code_md/cli.rb spec/cli_spec.rb README.md
git commit -m "feat: ccmd open runs a conversation end to end"
```

---

### Task 14: The `ls` and `trace` commands

**Files:**
- Modify: `lib/claude_code_md/cli.rb`
- Create: `lib/claude_code_md/conversation_index.rb`
- Create: `spec/conversation_index_spec.rb`

**Interfaces:**
- Consumes: `Location.directories`, `ConversationFile`.
- Produces: `ConversationIndex.entries(env:, cwd:, all:) -> Array<Hash>` with keys `:path`, `:session_id`, `:updated_at`; `ccmd ls [--all]`; `ccmd trace TARGET`.

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

  it "ignores trace files" do
    write_conversation(File.join(@dir, "global"), "conversation.8_5_2026.x.md", "aaa")
    File.write(File.join(@dir, "global", "conversation.8_5_2026.x.trace.md"), "## Turn 1\n")

    expect(described_class.entries(env: env, cwd: @dir).size).to eq(1)
  end

  it "scans both locations with all" do
    FileUtils.mkdir_p(File.join(@dir, "repo", ".git"))
    write_conversation(File.join(@dir, "repo", "docs/agent-local/conversations"), "conversation.8_5_2026.r.md", "rrr")
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
    # @param all [Boolean] true scans both the repo-relative and global directories
    def self.entries(env: ENV, cwd: Dir.pwd, all: false)
      directories(env: env, cwd: cwd, all: all)
        .flat_map { |dir| conversations_in(dir) }
        .sort_by { |entry| -entry[:updated_at].to_f }
    end

    def self.directories(env:, cwd:, all:)
      dirs = Location.directories(env: env, cwd: cwd)
      return dirs.values.compact if all

      [dirs[:repo] || dirs[:global]]
    end

    def self.conversations_in(dir)
      return [] unless dir&.directory?

      dir.glob("*.md").reject { |path| path.to_s.end_with?(".trace.md") }.map do |path|
        { path: path,
          session_id: ConversationFile.new(path).frontmatter[:session_id],
          updated_at: path.mtime }
      end
    end

    private_class_method :directories, :conversations_in
  end
end
```

Add these commands to `Cli`:

```ruby
    desc "ls", "List conversations with their session id and last activity"
    option :all, type: :boolean, default: false, desc: "Scan both the repo and global directories"
    def ls
      entries = ConversationIndex.entries(all: options[:all])
      return say("no conversations yet") if entries.empty?

      entries.each do |entry|
        say format("%-52s %s  %s", entry[:path].basename, entry[:updated_at].strftime("%-m/%-d/%Y %H:%M"),
                   entry[:session_id])
      end
    end

    desc "trace TARGET", "Print the path of a conversation's trace file"
    def trace(target)
      say ConversationFile.new(Location.resolve(target)).trace_path.to_s
    end
```

Add `require_relative "claude_code_md/conversation_index"` to `lib/claude_code_md.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/claude_code_md.rb lib/claude_code_md/cli.rb lib/claude_code_md/conversation_index.rb spec/conversation_index_spec.rb
git commit -m "feat: list conversations and locate their traces"
```

---

### Task 15: The `setup` command

**Files:**
- Modify: `lib/claude_code_md/cli.rb`
- Create: `lib/claude_code_md/editor_setup.rb`
- Create: `spec/editor_setup_spec.rb`
- Modify: `docs/designs/design.8_5_2026.ccmd_architecture.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `EditorSetup.new(keybindings_path:, tasks_path:)` with `#keybinding_snippet`, `#task_snippet`, `#write_task -> :created | :present`, `#write_keybinding -> :created | :present | :refused`; `ccmd setup [--write]`.

Writing is opt-in and conservative: VSCode config files are JSONC, and comments cannot be round-tripped by a JSON parser. `--write` therefore creates `tasks.json` when absent and refuses rather than mangling any file containing comments. Printing is the default.

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

  it "offers snippets that name the cc-send task and cmd+enter" do
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

Add to `Cli`:

```ruby
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

with these private helpers on `Cli`:

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

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rake`
Expected: all pass.

- [ ] **Step 5: Correct the design and README, then commit**

In the design, change "Editor wiring, which is one-time and what `ccmd setup` writes" to say that `ccmd setup` prints the wiring by default and writes it with `--write`, refusing files that contain comments. Add the same to the README.

```bash
git add lib/claude_code_md.rb lib/claude_code_md/cli.rb lib/claude_code_md/editor_setup.rb spec/editor_setup_spec.rb docs/designs/design.8_5_2026.ccmd_architecture.md README.md
git commit -m "feat: ccmd setup prints or installs the editor wiring"
```

---

## Manual Verification

Automated specs never touch the real CC, so run this once after Task 15:

- [ ] `ccmd setup --write` in a scratch directory, then confirm cmd+enter creates a `.send` file
- [ ] `ccmd scratch-test` inside a git repo, then confirm the file lands under `docs/agent-local/conversations`
- [ ] Type a question, press cmd+enter, and watch the reply stream in without the tab closing
- [ ] Edit a line higher up in the file while a reply streams, then confirm the reply still appends at the end and your edit survives
- [ ] Send a second turn while the first is still streaming, then confirm it runs after the first finishes rather than interleaving
- [ ] Ask for something that uses tools, then confirm the conversation stays prose-only and the trace holds full results
- [ ] Kill the `claude` child with `pkill -f 'claude -p'`, then confirm the next turn resumes the same session
- [ ] Ctrl+C, then confirm the conversation gets its interrupted note

## Self-Review Notes

- Spec coverage: every section of the design maps to a task. Conversation Location to Task 8, Trace File to Tasks 6 and 10, Send Sidecar to Task 7, CC Invocation to Task 9, the Components table to Tasks 5–12, CLI Surface to Tasks 13–15, Error Handling to Tasks 10 and 12 plus the Manual Verification list.
- Two places where the implementation intentionally diverges from the design, each with a step that corrects the design text rather than leaving a contradiction: `TurnState` collapses tool-wait (Task 11), and `ccmd setup` prints by default rather than writing (Task 15).
- `#interrupt` on `ClaudeProcess` is dropped in favor of stop-and-resume, because the control-protocol field shapes are unverified. The design already lists in-file approvals as deferred for the same reason; Task 9's Interfaces block records the substitution.
