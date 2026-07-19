module Scroll
  # Draws the tail window in place at the bottom of a terminal, overwriting the
  # previous frame each time. Lines are sanitized (control/escape bytes removed)
  # and truncated to the terminal width so a hostile stream cannot corrupt the
  # display region. The raw stream on STDOUT is never touched by any of this.
  class Renderer
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    CLEAR_LINE  = "\e[2K"

    def initialize(@io : IO, @sanitize : Bool = true)
      @drawn = 0
    end

    def start : Nil
      @io << HIDE_CURSOR
      @io.flush
    end

    def draw(lines : Array(String)) : Nil
      rows, cols = Terminal.size
      visible = lines.last(Math.min(lines.size, rows))
      sequence = String.build do |str|
        str << "\e[" << @drawn << 'A' if @drawn > 0
        visible.each do |line|
          str << CLEAR_LINE << prepare(line, cols) << "\r\n"
        end
        extra = @drawn - visible.size
        if extra > 0
          extra.times { str << CLEAR_LINE << "\r\n" }
          str << "\e[" << extra << 'A'
        end
      end
      @io << sequence
      @io.flush
      @drawn = visible.size
    end

    def finish : Nil
      @io << SHOW_CURSOR
      @io.flush
    end

    # Restore the cursor unconditionally; safe to call from an at_exit hook.
    def self.restore(io : IO) : Nil
      io << SHOW_CURSOR
      io.flush
    rescue IO::Error
      # Terminal already gone; nothing to restore.
    end

    private def prepare(line : String, cols : Int32) : String
      String.build do |str|
        width = 0
        line.each_char do |char|
          break if width >= cols
          if @sanitize
            code = char.ord
            if code == '\t'.ord
              char = ' '
            elsif code < 0x20 || code == 0x7F || (code >= 0x80 && code <= 0x9F)
              next
            end
          end
          str << char
          width += 1
        end
      end
    end
  end
end
