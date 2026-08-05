# frozen_string_literal: true

require_relative "lib/claude_code_md/version"

Gem::Specification.new do |spec|
  spec.name = "claude-code-md"
  spec.version = ClaudeCodeMd::VERSION
  spec.authors = ["Matthew Greenfield"]
  spec.email = ["mattgreenfield1@gmail.com"]

  spec.summary = "Talk to Claude Code in a markdown file instead of a terminal"
  spec.description = <<~DESC.strip
    ccmd turns a markdown file into a conversation with Claude Code. You write
    prompts in your editor, hit a key, and the reply streams into the same file
    below what you wrote. Thinking and tool activity go to a separate trace file
    so the conversation stays readable.
  DESC
  spec.homepage = "https://github.com/omgreenfield/claude-code-md"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/omgreenfield/claude-code-md"
  spec.metadata["changelog_uri"] = "https://github.com/omgreenfield/claude-code-md/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ docs/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = ["ccmd"]
  spec.require_paths = ["lib"]

  spec.add_dependency "omg-thor-ext", "~> 0.1"
  spec.add_dependency "thor", "~> 1.5"
end
