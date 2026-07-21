module Scroll
  # Draws the tail on the terminal's alternate screen buffer. Unlike Renderer,
  # which repaints N rows every frame, this appends complete lines and lets the
  # terminal do the scrolling. On exit the alt screen is torn down and the user's
  # original screen and scrollback are restored untouched.
  #
  # One class covers two modes, chosen by `@region`:
  #
  # * region mode (`@region` true): a DEC scrolling region (DECSTBM) of
  #   `min(N, rows)` rows is set inside the alt screen; only that band scrolls.
  #   Honors `-N`. A SIGWINCH must re-apply the region on resize.
  # * full mode (`@region` false): the whole alt screen scrolls naturally,
  #   ignoring `-N`. Tee-like. Used when DECSTBM is judged unsupported.
  #
  # STDOUT is never touched by any of this; the display lives entirely on the
  # STDERR IO handed to the constructor.
  class AltRenderer
    HIDE_CURSOR  = "\e[?25l"
    SHOW_CURSOR  = "\e[?25h"
    ENTER_ALT    = "\e[?1049h"
    LEAVE_ALT    = "\e[?1049l"
    RESET_REGION = "\e[r"
    CLEAR_HOME   = "\e[2J\e[H"

    NEWLINE = '\n'.ord.to_u8

    getter? region : Bool

    # `size` overrides the terminal size query (rows, cols); it exists so specs
    # can drive the renderer against an `IO::Memory`, which has no fd. In normal
    # use it is nil and the size is read from the terminal on `start` and on
    # every resize.
    def initialize(@io : IO, @lines : Int32, @sanitize : Bool = true,
                   region : Bool = true, @size : {Int32, Int32}? = nil)
      @region = region
      @rows = 0
      @cols = 0
      @height = 0 # rows in the scroll band (region) or on screen (full)
      @line = IO::Memory.new
      @pending = Deque(String).new # complete lines awaiting the next flush
      @recent = Deque(String).new  # ring of the last @lines for the finish echo
      @expected_offset = nil.as(Int64?)
      @skip_fragment = false
      @resized = Atomic(Bool).new(false)
    end

    # Enter the alt screen, hide the cursor, and (region mode) set the DECSTBM
    # band and park the cursor at its bottom-left so appended lines scroll up.
    def start : Nil
      read_size
      @io << ENTER_ALT << HIDE_CURSOR
      if region?
        emit_region
      else
        @io << CLEAR_HOME
      end
      @io.flush
    end

    # Feed a chunk of raw bytes that begins at byte `start` in the stream. Splits
    # into complete lines exactly as `Tail#feed` does: a gap (dropped chunk) skips
    # the interrupted line's tail up to the next newline; the trailing partial is
    # buffered until its newline arrives.
    def feed(bytes : Bytes, start : Int64) : Nil
      if expected = @expected_offset
        begin_gap unless start == expected
      end
      @expected_offset = start + bytes.size

      position = 0
      if @skip_fragment
        newline = bytes.index(NEWLINE, position)
        return unless newline # whole chunk is the dropped line's tail
        position = newline + 1
        @skip_fragment = false
      end

      while newline = bytes.index(NEWLINE, position)
        @line.write bytes[position...newline]
        push String.new(@line.to_slice)
        @line.clear
        position = newline + 1
      end
      @line.write bytes[position..] if position < bytes.size
    end

    # Write the pending lines, letting the terminal scroll. Re-applies the region
    # first if a resize was signalled. The pending buffer is capped to the band
    # height: scrolling through more than one bandful between frames is pointless,
    # since the earlier lines would instantly scroll off.
    def flush : Nil
      return if @pending.empty?
      apply_resize if @resized.get

      excess = @pending.size - @height
      excess.times { @pending.shift } if excess > 0

      width = line_width
      @pending.each { |line| @io << prepare(line, width) << "\r\n" }
      @pending.clear
      @io.flush
    end

    # On EOF: optionally promote a trailing newline-less line, drain the buffer,
    # tear down the alt screen, then echo the last `min(N, rows)` lines to the
    # restored main screen so the run leaves a visible tail behind (the alt screen
    # otherwise vanishes completely, like `less`).
    def finish(final : Bool) : Nil
      if final
        remainder = @line.to_slice
        unless remainder.empty? || @skip_fragment
          push String.new(remainder)
          @line.clear
        end
      end
      flush
      self.class.restore(@io)
      echo_recent
    end

    # Flag a terminal resize. Called from the SIGWINCH trap; it only flips the
    # atomic so the render fiber re-applies the region on its next flush — no
    # escapes are written from the signal handler.
    def notify_resize : Nil
      @resized.set(true)
    end

    # Show the cursor, reset any scroll region, and leave the alt screen. Safe to
    # call from an at_exit hook even if `start` never ran: `\e[?1049l` is a no-op
    # when the alt screen was never entered, and `\e[r` a no-op with no region.
    # Serves both modes.
    def self.restore(io : IO) : Nil
      io << SHOW_CURSOR << RESET_REGION << LEAVE_ALT
      io.flush
    rescue IO::Error
      # Terminal already gone; nothing to restore.
    end

    private def emit_region : Nil
      @io << "\e[2J\e[1;" << @height << 'r' << "\e[" << @height << ";1H"
    end

    private def apply_resize : Nil
      @resized.set(false)
      read_size
      emit_region if region?
    end

    private def read_size : Nil
      @rows, @cols = @size || Terminal.size
      @height = region? ? Math.min(@lines, @rows) : @rows
      @height = 1 if @height < 1
    end

    private def line_width : Int32
      @cols > 1 ? @cols - 1 : @cols
    end

    private def begin_gap : Nil
      @line.clear           # discard the partial head being assembled
      @skip_fragment = true # and discard the interrupted line's tail
    end

    private def push(line : String) : Nil
      @pending.push line
      @recent.push line
      @recent.shift if @recent.size > @lines
    end

    private def echo_recent : Nil
      return if @recent.empty?
      count = Math.min(@recent.size, Math.min(@lines, @rows))
      width = line_width
      @recent.to_a.last(count).each { |line| @io << prepare(line, width) << "\r\n" }
      @io.flush
    rescue IO::Error
      # Main screen already gone; nothing to echo.
    end

    # Sanitize and truncate to one short of the terminal width so each logical
    # line occupies exactly one terminal row and scrolling stays predictable.
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
