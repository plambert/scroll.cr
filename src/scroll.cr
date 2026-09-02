# scroll — copy STDIN to STDOUT unchanged while showing the tail of the stream
# in a live display on STDERR.
require "./scroll/tail"
require "./scroll/sorter"
require "./scroll/sort_window"
require "./scroll/terminal"
require "./scroll/progress"
require "./scroll/renderer"
require "./scroll/source"
require "./scroll/alt_renderer"
require "./scroll/cli"
require "./scroll/runner"

module Scroll
  {% begin %}
  VERSION = {{ `shards version`.strip.stringify }}
  {% end %}

  # `dispatch` handles --help, --version, the shell-completion install flag, and
  # parse/validation errors (reported as `scroll: message`, exit 1). The bare -N
  # shorthand is expanded first, since the parser has no numeric flag names.
  def self.run(args = ARGV.dup) : Nil
    CLI.dispatch(CLI.expand_count_shorthand(args))
  end
end
