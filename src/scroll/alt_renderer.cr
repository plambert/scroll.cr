module Scroll
  # Draws the tail on the terminal's alternate screen buffer. Unlike Renderer,
  # which repaints N rows every frame, this appends complete lines and lets the
  # terminal do the scrolling, which is what makes it keep up with a much faster
  # stream. The whole screen is used: `-N` bounds the inline display, not this
  # one.
  #
  # A scrolling region (DECSTBM) is set only with `--progress`, to hold the
  # bottom row back for the progress line; without it the screen scrolls
  # naturally. On exit the alt screen is torn down and the original screen and
  # scrollback are restored untouched — `--leave` then echoes the lines that were
  # visible onto the main screen, so the run leaves a tail behind.
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
    CLEAR_EOL    = "\e[K"
    SAVE_CURSOR  = "\e7"
    LOAD_CURSOR  = "\e8"

    NEWLINE = '\n'.ord.to_u8

    # `size` overrides the terminal size query (rows, cols); it exists so specs
    # can drive the renderer against an `IO::Memory`, which has no fd. In normal
    # use it is nil and the size is read from the terminal on `start` and on
    # every resize.
    def initialize(@io : IO, @sanitize : Bool = true, @progress : Bool = false,
                   @leave : Bool = false, @size : {Int32, Int32}? = nil)
      @rows = 0
      @cols = 0
      @height = 0 # rows the stream may scroll through
      @line = IO::Memory.new
      @pending = Deque(String).new # complete lines awaiting the next flush
      @recent = Deque(String).new  # ring of the visible lines, for --leave
      @expected_offset = nil.as(Int64?)
      @skip_fragment = false
      @wrote_line = false # whether a line already occupies the cursor's row
      @resized = Atomic(Bool).new(false)
    end

    # Enter the alt screen and hide the cursor. With a progress line, a DECSTBM
    # band covers every row but the last and the cursor parks at its bottom, so
    # appended lines scroll within it and the bar below stays put.
    def start : Nil
      read_size
      @io << ENTER_ALT << HIDE_CURSOR
      if @progress
        emit_region
      else
        @io << CLEAR_HOME
      end
      @io.flush
    end

    # Columns a row may use.
    def width : Int32
      line_width
    end

    # Paint the progress line on the bottom screen row, outside the scrolling
    # band, and put the cursor back where the band left it.
    def draw_progress(text : String) : Nil
      return unless @progress
      apply_resize if @resized.get
      # Written over the row and then cleared to its end, rather than clearing
      # first: an empty row between the two writes is a frame of flicker.
      @io << SAVE_CURSOR << "\e[" << @rows << ";1H" << text << CLEAR_EOL << LOAD_CURSOR
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
    # first if a resize was signalled. The pending buffer is capped to the screen
    # height: scrolling through more than one screenful between frames is
    # pointless, since the earlier lines would instantly scroll off.
    #
    # Lines are *separated* by CRLF rather than terminated by one. A terminating
    # newline scrolls the last line up and leaves the cursor on a blank row, so
    # under a fast stream the bottom row alternates between blank and filled once
    # a frame, which reads as a flicker. Separating instead leaves the newest line
    # sitting on that row until the next one pushes it up.
    def flush : Nil
      return if @pending.empty?
      apply_resize if @resized.get

      excess = @pending.size - @height
      excess.times { @pending.shift } if excess > 0

      width = line_width
      @pending.each do |line|
        @io << "\r\n" if @wrote_line
        @io << prepare(line, width)
        @wrote_line = true
      end
      @pending.clear
      @io.flush
    end

    # On EOF: optionally promote a trailing newline-less line, drain the buffer,
    # then tear down the alt screen. Under `--leave` the lines that were on the
    # screen are echoed onto the restored main screen; otherwise the run vanishes
    # completely, like `less`.
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
      echo_recent if @leave
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
    def self.restore(io : IO) : Nil
      io << SHOW_CURSOR << RESET_REGION << LEAVE_ALT
      io.flush
    rescue IO::Error
      # Terminal already gone; nothing to restore.
    end

    private def emit_region : Nil
      @io << "\e[2J\e[1;" << @height << 'r' << "\e[" << @height << ";1H"
      @wrote_line = false # the screen is blank again
    end

    private def apply_resize : Nil
      @resized.set(false)
      read_size
      emit_region if @progress
    end

    private def read_size : Nil
      @rows, @cols = @size || Terminal.size
      @height = @progress ? @rows - 1 : @rows # the bottom row holds the bar
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
      return unless @leave
      @recent.push line
      while @recent.size > @height
        @recent.shift
      end
    end

    private def echo_recent : Nil
      return if @recent.empty?
      width = line_width
      @recent.each { |line| @io << prepare(line, width) << "\r\n" }
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
