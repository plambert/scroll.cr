require "shell-auto_complete"

module Scroll
  HELP_FOOTER = <<-HELP_FOOTER
    A bare -N is shorthand for --lines N (e.g. -20 means --lines 20).

    Examples:
      long-running-build | scroll -20 | tee build.log
      noisy-job | scroll --null                     watch the tail, discard output
      scroll -f app.log --pid $(pgrep -f app)       follow a file until app exits
      du -sh * | scroll --null --sort --human       keep the largest on screen
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

    # Which alternate-screen rendering to use when --alt is on. Auto picks Region
    # when DECSTBM is judged supported, else Full.
    enum AltMode
      Auto
      Region
      Full
    end

    flag lines : Int32 = DEFAULT_LINES, "--lines COUNT", "-n",
      "Lines to show (default: 10)", range: 1.., complete_with: :complete_none

    flag interval_ms : Int32 = DEFAULT_INTERVAL, "--interval MS",
      "Minimum ms between redraws (default: 40)", range: 0.., complete_with: :complete_none

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

    # Typed as Path for the value semantics. The shard only consults a type's
    # __arg_complete for positionals, not for flag values, so the filesystem
    # completion is requested explicitly via complete_with:.
    flag file : Path?, "--file PATH", "-f",
      "Follow PATH like `tail -F` instead of reading STDIN (implies --null)",
      group: "Following a file", complete_with: :complete_path

    flag from_start : Bool = false, "--from-start",
      "Stream the whole existing file before following",
      group: "Following a file", negatable: false

    flag poll_ms : Int32 = DEFAULT_POLL, "--poll MS",
      "Ms between polls while waiting for data (default: 250)",
      group: "Following a file", range: 1.., complete_with: :complete_none

    flag pid : Int32?, "--pid PID",
      "Exit cleanly once process PID is gone",
      group: "Following a file", range: 1.., complete_with: :complete_none

    flag watch_proc : Bool = false, "--watch-proc",
      "Exit once no process holds the file open for writing (Linux only)",
      group: "Following a file", negatable: false

    flag watch_proc_timeout_s : Int32 = DEFAULT_WATCH_TIMEOUT, "--watch-proc-timeout SEC",
      "Idle seconds before --watch-proc exits (default: 10)",
      group: "Following a file", range: 1.., complete_with: :complete_none

    flag sort : Bool = false, "--sort", "-s",
      "Show the top N of the whole stream, not the last N (STDOUT keeps input order)",
      group: "Sorting", negatable: false

    flag reverse : Bool = false, "--reverse", "-r",
      "Reverse the order (keep the smallest instead of the largest)",
      group: "Sorting", negatable: false

    flag sort_by : SortKey?, "--sort-by SPEC",
      "Sort key: a 1-based column number, or a /regex/ (implies --sort)",
      group: "Sorting", transform_with: :transform_sort_key, complete_with: :complete_none

    flag human : Bool = false, "--human",
      "Compare keys as human numbers, e.g. 1k < 2M (implies --sort)",
      group: "Sorting", negatable: false

    flag alt : Bool = false, "--alt",
      "Draw on the alternate screen: faster, and it vanishes on exit",
      group: "Alternate screen", negatable: false

    flag alt_region : Bool = false, "--alt-region",
      "Force region mode, which honors -N",
      group: "Alternate screen", negatable: false

    flag alt_full : Bool = false, "--alt-full",
      "Force full mode, which ignores -N and uses the whole screen",
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

    # Any of the three --alt spellings turns the alternate screen on.
    def alt? : Bool
      @alt || @alt_region || @alt_full
    end

    def alt_mode : AltMode
      return AltMode::Region if @alt_region
      return AltMode::Full if @alt_full
      AltMode::Auto
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

      raise Shell::AutoComplete::ParseError.new "--alt-region and --alt-full are mutually exclusive" if @alt_region && @alt_full

      if watch_proc?
        {% unless flag?(:linux) %}
          raise Shell::AutoComplete::ParseError.new "--watch-proc is only supported on Linux"
        {% end %}
      end
    end

    def run
      validate!
      Runner.new(self).run
    end

    # A value the shell cannot usefully guess (a count, a pid, a sort spec).
    # Returning no candidates stops the parser falling back to offering flag
    # names, which would otherwise complete `-n <TAB>` to `--lines`.
    def self.complete_none(context : Shell::AutoComplete::CompletionContext) : Array(String)
      [] of String
    end

    # Ask the shell to complete this flag's value with its own filesystem
    # completion (it handles ~, trailing slashes, and colouring far better than
    # we could enumerate here).
    def self.complete_path(context : Shell::AutoComplete::CompletionContext) : Array(String)
      [Shell::AutoComplete::Completion::Directive::FILES]
    end

    # Parse a `--sort-by` SPEC into a SortKey. A fully slash-delimited `/.../`
    # value is a PCRE2 regex; anything else must be a 1-based integer column.
    def self.transform_sort_key(value : String) : SortKey
      if value.size >= 2 && value.starts_with?('/') && value.ends_with?('/')
        inner = value[1..-2]
        begin
          SortKey::Pattern.new(Regex.new(inner))
        rescue ex : ArgumentError | Regex::Error
          raise ArgumentError.new "--sort-by: invalid regex: #{ex.message}"
        end
      else
        index = value.to_i? || raise ArgumentError.new "--sort-by: not an integer: #{value}"
        raise ArgumentError.new "--sort-by: must be >= 1" if index < 1
        SortKey::Field.new(index)
      end
    end

    # Translate a bare `-N` token (e.g. -20) into `--lines N`, leaving every other
    # token untouched. Applied before dispatch, since the parser has no notion of
    # a numeric flag name.
    def self.expand_count_shorthand(opts : Array(String)) : Array(String)
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
  end
end
