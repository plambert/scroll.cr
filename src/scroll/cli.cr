require "shell-auto_complete"

module Scroll
  HELP_FOOTER = <<-HELP_FOOTER
    A bare -N is shorthand for --lines N (e.g. -20 means --lines 20); -c and -C
    are shorthand for --color on and --color off.

    --fullscreen draws on the alternate screen, which uses the whole screen and
    ignores -N. It vanishes on exit unless --leave echoes what was visible.

    Examples:
      long-running-build | scroll -20 | tee build.log
      noisy-job | scroll --null                     watch the tail, discard output
      scroll -f app.log --pid $(pgrep -f app)       follow a file until app exits
      du -sh * | scroll --null --sort --human       keep the largest on screen
      tar cf - src | scroll --size 4G --name src    watch progress with a label
    HELP_FOOTER

  # The command-line surface. `Shell::AutoComplete` derives the parser, --help,
  # and the bash/zsh/fish completions from these declarations, so a new flag only
  # has to be added here. Bool flags are negatable, which is what gives --null its
  # --no-null counterpart (and --sanitize its --no-sanitize).
  Shell::AutoComplete.command CLI,
    name: "scroll",
    description: "Show a live tail of a stream on STDERR while copying it to STDOUT",
    footer: HELP_FOOTER do
    DEFAULT_LINES         =  10
    DEFAULT_INTERVAL      =  40
    DEFAULT_POLL          = 250
    DEFAULT_WATCH_TIMEOUT =  10

    # When to colorize the progress line. Auto follows the display.
    enum ColorMode
      Auto
      On
      Off
    end

    flag lines : Int32 = DEFAULT_LINES, "--lines COUNT", "-n",
      "Lines to show (default: 10)", range: 1..

    flag interval_ms : Int32 = DEFAULT_INTERVAL, "--interval MS",
      "Minimum ms between redraws (default: 40)", range: 0..

    flag force : Bool = false, "--force",
      "Draw the display even when STDERR is not a TTY"

    flag sanitize : Bool = true, "--sanitize",
      "Strip control/escape bytes from the display (--no-sanitize to keep them)"

    flag final : Bool = false, "--final",
      "On EOF, also show a trailing line that has no newline"

    # Tri-state: unset (nil), --null (true), --no-null (false). Resolved in Runner
    # against any mode that implies null, so --no-null can override --file.
    flag null : Bool?, "--null",
      "Consume input without copying it to STDOUT (--no-null forces the copy)"

    # Path-typed, so the generated completions delegate to the shell's own
    # filesystem completion for this flag's value.
    flag file : Path?, "--file PATH", "-f",
      "Follow PATH like `tail -F`, starting with its last -N lines (implies --null)",
      group: "Following a file"

    flag from_start : Bool = false, "--from-start",
      "Stream the whole existing file before following",
      group: "Following a file", negatable: false

    flag poll_ms : Int32 = DEFAULT_POLL, "--poll MS",
      "Ms between polls while waiting for data (default: 250)",
      group: "Following a file", range: 1..

    flag pid : Int32?, "--pid PID",
      "Exit cleanly once process PID is gone",
      group: "Following a file", range: 1..

    flag watch_proc : Bool = false, "--watch-proc",
      "Exit once no process holds the file open for writing (Linux only)",
      group: "Following a file", negatable: false

    flag watch_proc_timeout_s : Int32 = DEFAULT_WATCH_TIMEOUT, "--watch-proc-timeout SEC",
      "Idle seconds before --watch-proc exits (default: 10)",
      group: "Following a file", range: 1..

    flag sort : Bool = false, "--sort", "-s",
      "Show the top N of the whole stream, not the last N (STDOUT keeps input order)",
      group: "Sorting", negatable: false

    flag reverse : Bool = false, "--reverse", "-r",
      "Reverse the order (keep the smallest instead of the largest)",
      group: "Sorting", negatable: false

    flag sort_by : SortKey?, "--sort-by SPEC",
      "Sort key: a 1-based column number, or a /regex/ (implies --sort)",
      group: "Sorting", transform_with: :transform_sort_key

    flag human : Bool = false, "--human",
      "Compare keys as human numbers, e.g. 1k < 2M (implies --sort)",
      group: "Sorting", negatable: false

    flag progress : Bool = false, "--progress",
      "Show a progress line under the tail",
      group: "Progress", negatable: false

    # The three size options all turn --progress on, the way --sort-by turns on
    # --sort: naming a size is only useful to the progress line.
    flag size : Int64?, "--size BYTES",
      "Expected input size, e.g. 500M (1024-based); implies --progress",
      group: "Progress", transform_with: :transform_size

    flag size_lines : Int64?, "--size-lines COUNT",
      "Expected input size in lines; implies --progress",
      group: "Progress", range: 1_i64..

    flag size_file : Path?, "--file-size PATH",
      "Take the expected input size from the size of PATH; implies --progress",
      group: "Progress"

    # A Path rather than a String so the shells complete it as a filename; any
    # string is a valid Path, so an arbitrary label still parses.
    flag name : Path?, "--name NAME",
      "Label to show in the progress line; implies --progress",
      group: "Progress"

    # Tri-state, like --null: nil asks the terminal what it is, true and false
    # settle it without asking. --no-terminal-progress therefore also means "do
    # not query the terminal at all".
    flag terminal_progress : Bool?, "--terminal-progress",
      "Drive the terminal's own progress indicator (--no- skips even the query)",
      group: "Progress"

    flag color : ColorMode = ColorMode::Auto, "--color WHEN",
      "Colorize the progress line (-c is --color on, -C is --color off)",
      group: "Progress"

    flag progress_charset : Progress::Charset = Progress::Charset::Unicode, "--progress-charset SET",
      "Bar glyphs: unicode draws eighth-of-a-column steps, ascii stays in ASCII",
      group: "Progress"

    flag fullscreen : Bool = false, "--fullscreen",
      "Draw on the alternate screen: faster, uses the whole screen, ignores -N",
      group: "Alternate screen"

    flag leave : Bool = false, "--leave",
      "On exit, echo the lines that were on the alternate screen",
      group: "Alternate screen", negatable: false

    # Bool predicates, so the rest of the codebase reads `config.force?` rather
    # than the plain property the macro generates.
    def force? : Bool
      @force
    end

    def sanitize? : Bool
      @sanitize
    end

    def final? : Bool
      @final
    end

    def from_start? : Bool
      @from_start
    end

    def watch_proc? : Bool
      @watch_proc
    end

    def reverse? : Bool
      @reverse
    end

    def human? : Bool
      @human
    end

    # --sort-by and --human both imply --sort.
    def sort? : Bool
      @sort || @human || !@sort_by.nil?
    end

    # True when following a file. Passed to Runner as the "mode implies null"
    # input so file mode is silent on STDOUT unless --no-null re-enables teeing.
    def file? : Bool
      !@file.nil?
    end

    # Naming any part of the input size, or a label, turns the progress line on.
    def progress? : Bool
      @progress || !@size.nil? || !@size_lines.nil? || !@size_file.nil? ||
        !@name.nil? || @terminal_progress == true
    end

    # The --name label, sanitized of control bytes when the display draws it.
    def name_text : String?
      @name.try &.to_s
    end

    def fullscreen? : Bool
      @fullscreen
    end

    def leave? : Bool
      @leave
    end

    # Whether the progress line is colorized, for the terminal this run has.
    def color? : Bool
      CLI.color_enabled?(@color, STDERR.tty?, ENV["NO_COLOR"]?.presence, ENV["TERM"]?)
    end

    # Auto follows the display: color when STDERR is a terminal, unless NO_COLOR
    # is set or $TERM says the terminal cannot show it.
    def self.color_enabled?(mode : ColorMode, stderr_tty : Bool, no_color : String?, term : String?) : Bool
      case mode
      in .on?   then true
      in .off?  then false
      in .auto? then stderr_tty && no_color.nil? && !term.nil? && !term.empty? && term != "dumb"
      end
    end

    # Run the cross-flag rules after parsing, before `run`. As a hook they cannot
    # be forgotten by a future entry point the way an explicit call at the top of
    # `run` can.
    before_run do
      validate!
    end

    # Cross-flag rules the per-flag types cannot express. Raises ParseError so
    # `dispatch` reports it the same way it reports a bad flag value.
    def validate! : Nil
      unless file?
        {"--from-start" => from_start?, "--watch-proc" => watch_proc?}.each do |name, given|
          raise Shell::AutoComplete::ParseError.new "#{name} requires --file" if given
        end
        raise Shell::AutoComplete::ParseError.new "--pid requires --file" if @pid
        raise Shell::AutoComplete::ParseError.new "--poll requires --file" if @poll_ms != DEFAULT_POLL
        if @watch_proc_timeout_s != DEFAULT_WATCH_TIMEOUT
          raise Shell::AutoComplete::ParseError.new "--watch-proc-timeout requires --file"
        end
      end

      raise Shell::AutoComplete::ParseError.new "--leave requires --fullscreen" if leave? && !fullscreen?

      if path = @size_file
        raise Shell::AutoComplete::ParseError.new "--file-size: not a file: #{path}" unless File.file?(path)
      end

      if watch_proc?
        {% unless flag?(:linux) %}
          raise Shell::AutoComplete::ParseError.new "--watch-proc is only supported on Linux"
        {% end %}
      end
    end

    def run
      Runner.new(self).run
    end

    # Parse a `--sort-by` SPEC into a SortKey. A fully slash-delimited `/.../`
    # value is a PCRE2 regex; anything else must be a 1-based integer column.
    def self.transform_sort_key(value : String) : SortKey
      if value.size >= 2 && value.starts_with?('/') && value.ends_with?('/')
        inner = value[1..-2]
        begin
          SortKey::Pattern.new(Regex.new(inner))
        rescue ex : ArgumentError | Regex::Error
          raise ArgumentError.new "invalid regex: #{ex.message}"
        end
      else
        index = value.to_i? || raise ArgumentError.new "not an integer: #{value}"
        raise ArgumentError.new "must be >= 1" if index < 1
        SortKey::Field.new(index)
      end
    end

    # Parse a `--size` value into a byte count: an integer, or a decimal with a
    # 1024-based suffix (100b, 1.1k, 2.5GiB).
    def self.transform_size(value : String) : Int64
      Progress.parse_size value
    end

    # Translate the shorthand tokens the parser has no notion of: a bare `-N`
    # (e.g. -20) into `--lines N`, and -c/-C into `--color on`/`--color off`.
    # Everything else is passed through untouched.
    #
    # A completion callback (`__complete <cword> <words...>`, emitted by the
    # generated bash/zsh/fish wrappers) is passed through untouched. Rewriting one
    # token into two would shift every word after it without moving `cword`, so the
    # shell would be offered candidates for the wrong word.
    def self.expand_count_shorthand(opts : Array(String)) : Array(String)
      return opts.dup if opts.first? == "__complete"

      result = [] of String
      opts.each do |token|
        case token
        when /\A-(\d+)\z/ then result << "--lines" << $~[1]
        when "-c"         then result << "--color" << "on"
        when "-C"         then result << "--color" << "off"
        else                   result << token
        end
      end
      result
    end
  end
end
