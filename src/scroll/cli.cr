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
      noisy-job | scroll --null   # watch the tail, discard the output
      scroll -f /var/log/app.log --pid $(pgrep -f app)   # follow until app exits
      scroll -f build.log --no-null | tee copy.log       # follow and tee STDOUT
    HELP_FOOTER

  # Parsed command-line configuration. The constructor takes an Array(String)
  # so it can be exercised directly in specs.
  class CLI
    DEFAULT_LINES         =  10
    DEFAULT_INTERVAL      =  40
    DEFAULT_POLL          = 250
    DEFAULT_WATCH_TIMEOUT =  10

    property lines : Int32 = DEFAULT_LINES
    property interval_ms : Int32 = DEFAULT_INTERVAL
    property? force : Bool = false
    property? sanitize : Bool = true
    property? final : Bool = false
    # nil = unspecified, true = --null, false = --no-null. Resolved in Runner
    # together with any mode (e.g. --file) that implies null.
    property null : Bool? = nil
    # --file/-f PATH: follow this file (tail -F) instead of reading STDIN.
    property file : String? = nil
    property poll_ms : Int32 = DEFAULT_POLL
    property pid : Int32? = nil
    property? from_start : Bool = false
    property? watch_proc : Bool = false
    property watch_proc_timeout_s : Int32 = DEFAULT_WATCH_TIMEOUT

    # True when following a file. Passed to Runner as the "mode implies null"
    # input so file mode is silent on STDOUT unless --no-null re-enables teeing.
    def file? : Bool
      !@file.nil?
    end

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
        parser.on("--null", "Consume STDIN without copying it to STDOUT") { @null = true }
        parser.on("--no-null", "Force copying STDIN to STDOUT, even in modes that imply --null (e.g. --file)") { @null = false }
        parser.on("-f PATH", "--file PATH", "Follow PATH like `tail -F` instead of reading STDIN (STDOUT silent unless --no-null)") { |value| @file = value }
        parser.on("--from-start", "With --file, stream the whole existing file before following") { @from_start = true }
        parser.on("--poll MS", "With --file, ms between polls while waiting for data (default: #{DEFAULT_POLL})") do |value|
          @poll_ms = parse_int value, "--poll"
        end
        parser.on("--pid INT", "With --file, exit cleanly once process INT is gone") do |value|
          @pid = parse_int value, "--pid"
        end
        parser.on("--watch-proc", "With --file, exit once no process holds the file open for writing (Linux only)") { @watch_proc = true }
        parser.on("--watch-proc-timeout SEC", "Idle seconds before --watch-proc exits (default: #{DEFAULT_WATCH_TIMEOUT})") do |value|
          @watch_proc_timeout_s = parse_int value, "--watch-proc-timeout"
        end
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
      validate_file_options
    end

    # The follow knobs only mean something with --file. --watch-proc is Linux
    # only; reject it elsewhere so a portable script fails loudly rather than
    # silently never exiting.
    private def validate_file_options : Nil
      raise ArgumentError.new "--pid must be > 0" if (pid = @pid) && pid <= 0
      raise ArgumentError.new "--poll must be >= 1" if @poll_ms < 1
      raise ArgumentError.new "--watch-proc-timeout must be >= 1" if @watch_proc_timeout_s < 1

      unless file?
        raise ArgumentError.new "--from-start requires --file" if from_start?
        raise ArgumentError.new "--pid requires --file" if @pid
        raise ArgumentError.new "--poll requires --file" if @poll_ms != DEFAULT_POLL
        raise ArgumentError.new "--watch-proc requires --file" if watch_proc?
        raise ArgumentError.new "--watch-proc-timeout requires --file" if @watch_proc_timeout_s != DEFAULT_WATCH_TIMEOUT
      end

      if watch_proc?
        {% unless flag?(:linux) %}
          raise ArgumentError.new "--watch-proc is only supported on Linux"
        {% end %}
      end
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
