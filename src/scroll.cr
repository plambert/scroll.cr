# scroll — copy STDIN to STDOUT unchanged while showing the tail of the stream
# in a live display on STDERR.
require "./scroll/tail"
require "./scroll/sorter"
require "./scroll/terminal"
require "./scroll/renderer"
require "./scroll/source"
require "./scroll/cli"
require "./scroll/runner"

module Scroll
  {% begin %}
  VERSION = {{ `shards version`.strip.stringify }}
  {% end %}

  def self.run(args = ARGV.dup) : Nil
    config = CLI.new(args)
    Runner.new(config).run
  rescue ex : ArgumentError
    STDERR.puts "scroll: #{ex.message}"
    exit 2
  end
end
