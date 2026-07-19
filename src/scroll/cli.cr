require "option_parser"

module Scroll
  HELP_BANNER = <<-HELP_BANNER
    Usage: scroll [options]

    Copy STDIN to STDOUT unchanged while showing the last N lines of the stream
    in a live, in-place display on STDERR. Intended as a pipeline filter: the
    STDOUT copy is never slowed by the display, and the display only ever shows
    a contiguous run of the most recent complete lines.

    Options:
    HELP_BANNER

  HELP_FOOTER = <<-HELP_FOOTER

    A bare -N is shorthand for --lines N (e.g. -20 means --lines 20).

    Examples:
      long-running-build | scroll -20 | tee build.log
      tail -f access.log | scroll | grep -v healthcheck > filtered.log
    HELP_FOOTER

  # Parsed command-line configuration. The constructor takes an Array(String)
  # so it can be exercised directly in specs.
  class CLI
    DEFAULT_LINES    = 10
    DEFAULT_INTERVAL = 40

    property lines : Int32 = DEFAULT_LINES
    property interval_ms : Int32 = DEFAULT_INTERVAL
    property? force : Bool = false
    property? sanitize : Bool = true
    property? final : Bool = false

    def initialize(opts = ARGV.dup)
      opts = expand_count_shorthand(opts)
      parser = OptionParser.new do |parser|
        parser.banner = HELP_BANNER
        parser.on("-n INT", "--lines INT", "Lines to show (default: #{DEFAULT_LINES})") do |value|
          @lines = parse_int value, "--lines"
        end
        parser.on("--interval MS", "Minimum ms between redraws (default: #{DEFAULT_INTERVAL})") do |value|
          @interval_ms = parse_int value, "--interval"
        end
        parser.on("--force", "Draw the display even when STDERR is not a TTY") { @force = true }
        parser.on("--no-sanitize", "Do not strip control/escape bytes from the display") { @sanitize = false }
        parser.on("--final", "On EOF, also show a trailing line that has no newline") { @final = true }
        parser.on("--version", "Show version and exit") do
          puts "#{PROGRAM_NAME} #{VERSION}"
          exit 0
        end
        parser.on("-h", "--help", "Show this help and exit") do
          puts parser
          puts HELP_FOOTER
          exit 0
        end
        parser.invalid_option { |opt| raise ArgumentError.new "#{opt}: unknown option" }
        parser.unknown_args do |args|
          next if args.empty?
          first = args.first
          if first.starts_with?('-')
            raise ArgumentError.new "#{first}: unknown option"
          else
            raise ArgumentError.new "unexpected argument: #{first}"
          end
        end
      end
      parser.parse(opts)

      raise ArgumentError.new "--lines must be >= 1" if @lines < 1
      raise ArgumentError.new "--interval must be >= 0" if @interval_ms < 0
    end

    # Translate a bare `-N` token (e.g. -20) into `--lines N`, leaving every
    # other token untouched. `-n` and other flags never match the pattern.
    private def expand_count_shorthand(opts : Array(String)) : Array(String)
      result = [] of String
      opts.each do |token|
        if match = token.match(/\A-(\d+)\z/)
          result << "--lines" << match[1]
        else
          result << token
        end
      end
      result
    end

    private def parse_int(value : String, flag : String) : Int32
      value.to_i? || raise ArgumentError.new "#{flag}: not an integer: #{value}"
    end
  end
end
