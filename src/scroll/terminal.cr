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

      fun ioctl(fd : LibC::Int, request : LibC::ULong, winsize : Winsize*) : LibC::Int
    end

    # Returns {rows, columns} for the terminal on `fd` (STDERR by default).
    def self.size(fd : Int32 = 2) : {Int32, Int32}
      winsize = LibTerminal::Winsize.new
      if LibTerminal.ioctl(fd, TIOCGWINSZ, pointerof(winsize)) == 0 &&
         winsize.ws_row > 0 && winsize.ws_col > 0
        {winsize.ws_row.to_i, winsize.ws_col.to_i}
      else
        {env_int("LINES", FALLBACK_ROWS), env_int("COLUMNS", FALLBACK_COLS)}
      end
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
