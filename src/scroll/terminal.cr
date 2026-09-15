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

    # The stdlib binds VMIN but not VTIME, which is what puts a deadline on the
    # probe's read.
    {% if flag?(:darwin) %}
      VTIME = 17
    {% else %}
      VTIME = 5
    {% end %}

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
        probe_mode(tty.fd, timeout) do
          tty << VERSION_QUERY
          tty.flush
          read_answer tty.fd
        end
      end
    rescue File::Error | IO::Error
      # No controlling terminal, or it never answered.
      nil
    end

    # Put the terminal in raw mode with a read deadline, run the probe, and put
    # it back however that goes.
    #
    # The deadline is the terminal driver's own (VMIN 0, VTIME in tenths of a
    # second), not the event loop's: /dev/tty is a File to Crystal, and a File
    # cannot be registered with kqueue ("kevent: Invalid argument"), so an
    # evented read raises where a blocking one would wait forever on a terminal
    # that answers nothing.
    private def self.probe_mode(fd : Int32, timeout : Time::Span, &)
      saved = uninitialized LibC::Termios
      return unless LibC.tcgetattr(fd, pointerof(saved)) == 0

      probing = saved
      LibC.cfmakeraw(pointerof(probing))
      probing.c_cc[LibC::VMIN] = 0_u8
      probing.c_cc[VTIME] = (timeout.total_milliseconds / 100).ceil.clamp(1, 255).to_u8
      return unless LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(probing)) == 0

      begin
        yield
      ensure
        LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(saved))
      end
    end

    # Read whatever the terminal sends back. Each read returns as soon as the
    # driver has bytes, or empty-handed once VTIME expires.
    private def self.read_answer(fd : Int32) : String?
      answer = IO::Memory.new
      buffer = Bytes.new(64)

      while answer.bytesize < 256
        count = LibC.read(fd, buffer, buffer.size)
        break if count <= 0
        answer.write buffer[0, count.to_i32]
        # The reply is a DCS string; either terminator ends it.
        text = answer.to_s
        break if text.ends_with?("\e\\") || text.ends_with?('\a')
      end

      answer.empty? ? nil : answer.to_s
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
