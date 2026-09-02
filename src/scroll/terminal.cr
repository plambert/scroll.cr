module Scroll
  # Queries the size of the terminal attached to a file descriptor via
  # TIOCGWINSZ, falling back to the LINES/COLUMNS environment variables and then
  # to a conventional 24x80.
  module Terminal
    {% if flag?(:darwin) %}
      TIOCGWINSZ = 0x40087468_u64
    {% else %}
      TIOCGWINSZ = 0x5413_u64
    {% end %}

    FALLBACK_ROWS = 24
    FALLBACK_COLS = 80

    lib LibTerminal
      struct Winsize
        ws_row : LibC::UShort
        ws_col : LibC::UShort
        ws_xpixel : LibC::UShort
        ws_ypixel : LibC::UShort
      end

      # `ioctl` is variadic in C. It MUST be declared variadic here: on the
      # Apple ARM64 ABI a fixed trailing parameter is passed in a register while
      # libc reads the variadic argument from the stack, so a fixed-arg binding
      # passes a garbage pointer and the call fails (returning -1, size 0).
      fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int

      # Not bound by the stdlib. Used to tell whether this process owns the
      # terminal before reading from it.
      fun tcgetpgrp(fd : LibC::Int) : LibC::PidT
    end

    # Returns {rows, columns} for the terminal on `fd`. The display lives on
    # STDERR, so that is the stream whose size matters — never STDOUT, which is
    # usually redirected in a pipeline.
    def self.size(fd : Int32 = STDERR.fd) : {Int32, Int32}
      winsize = LibTerminal::Winsize.new
      if LibTerminal.ioctl(fd, TIOCGWINSZ, pointerof(winsize)) == 0 &&
         winsize.ws_row > 0 && winsize.ws_col > 0
        {winsize.ws_row.to_i, winsize.ws_col.to_i}
      else
        {env_int("LINES", FALLBACK_ROWS), env_int("COLUMNS", FALLBACK_COLS)}
      end
    end

    # Terminals known to show OSC 9;4 progress. XTVERSION answers with the name,
    # e.g. "\eP>|ghostty 1.2.0\e\\".
    PROGRESS_TERMINALS = %w[kitty ghostty iterm]

    VERSION_QUERY   = "\e[>q" # XTVERSION
    VERSION_TIMEOUT = 100.milliseconds

    # Whether `response` names a terminal that drives its own progress
    # indicator. Anything else — no answer, or a terminal that is not on the
    # list — means the sequence is not worth sending.
    def self.reports_progress?(response : String?) : Bool
      return false unless response
      lowered = response.downcase
      PROGRESS_TERMINALS.any? { |name| lowered.includes?(name) }
    end

    # Ask the controlling terminal to name itself, returning its answer or nil
    # when it does not answer within `timeout` — which is the usual case, since
    # a terminal that does not know the query stays silent.
    #
    # The query goes to /dev/tty rather than STDIN, which belongs to the stream
    # being copied, and is skipped outside the foreground process group: reading
    # the terminal from the background raises SIGTTIN, which would stop the run.
    def self.version_response(timeout : Time::Span = VERSION_TIMEOUT) : String?
      File.open("/dev/tty", "r+") do |tty|
        next unless tty.tty? && foreground?(tty)
        tty.raw do
          tty << VERSION_QUERY
          tty.flush
          tty.read_timeout = timeout
          buffer = Bytes.new(64)
          count = tty.read(buffer)
          count > 0 ? String.new(buffer[0, count]) : nil
        end
      end
    rescue File::Error | IO::Error
      # No controlling terminal, or it never answered.
      nil
    end

    private def self.foreground?(tty : IO::FileDescriptor) : Bool
      LibTerminal.tcgetpgrp(tty.fd).to_i64 == Process.pgid
    end

    private def self.env_int(name : String, default : Int32) : Int32
      if value = ENV[name]?
        parsed = value.to_i?
        return parsed if parsed && parsed > 0
      end
      default
    end
  end
end
