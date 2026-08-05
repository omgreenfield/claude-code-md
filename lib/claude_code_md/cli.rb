# frozen_string_literal: true

require "thor"
require "thor_ext"

require_relative "version"

module ClaudeCodeMd
  # Command-line surface for `ccmd`.
  #
  # Only version reporting is wired up so far. The remaining commands are
  # specified in docs/designs and land as that design is implemented.
  class Cli < Thor
    extend ThorExt::Start

    map %w[-v --version] => :version

    desc "version", "Print the ccmd version"
    def version
      say ClaudeCodeMd::VERSION
    end

    def self.exit_on_failure? = true
  end
end
