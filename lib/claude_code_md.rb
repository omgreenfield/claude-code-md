# frozen_string_literal: true

require_relative "claude_code_md/version"
require_relative "claude_code_md/cli"

# Markdown-file conversations with CC.
#
# You write prompts into a markdown file in your editor and CC appends its
# replies to that same file. The user-facing entry point is the `ccmd`
# executable, which delegates to {ClaudeCodeMd::Cli}.
module ClaudeCodeMd
  class Error < StandardError; end
end
