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

    # Whether to assume the terminal honors DECSTBM (the scrolling region used by
    # --alt region mode). DECSTBM is original VT100 and is implemented by every
    # terminal that also supports the alternate screen, so a tty probe or a
    # terminfo dependency would only re-derive "assume yes" at real cost. Instead,
    # deny only the terminals that plainly are not VT: $TERM unset, empty, or
    # "dumb". A false positive is recoverable with --alt-full.
    def self.scroll_region_supported? : Bool
      term = ENV["TERM"]?
      return false if term.nil? || term.empty? || term == "dumb"
      true
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
