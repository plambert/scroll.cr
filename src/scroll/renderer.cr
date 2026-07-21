module Scroll
  # Draws the tail window as a fixed-height region on the terminal, repainting it
  # in place each frame. The region is reserved once by scrolling (which pushes
  # any existing screen content up into scrollback rather than overwriting it),
  # and thereafter every frame is a single up-move, N cleared-and-rewritten rows,
  # and a move back to the top. No newline is ever emitted after the last row, so
  # the terminal never scrolls again and the region cannot drift or clobber
  # history. Lines are sanitized and truncated to one short of the terminal width
  # (never touching the last column, which can trigger auto-wrap). The raw stream
  # on STDOUT is never touched by any of this.
  class Renderer
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    CLEAR_LINE  = "\e[2K"

    def initialize(@io : IO, @lines : Int32, @sanitize : Bool = true)
      @max = 0      # largest height the region may reach (set in #start)
      @height = 0   # rows currently reserved; grows toward @max as lines arrive
      @done = false # guards #finish against running twice
      @started = false
    end

    # Hide the cursor and record the ceiling for the region height. The region is
    # not reserved up front: it grows one row at a time as lines arrive, so a
    # short stream never opens more rows than it has lines.
    def start : Nil
      rows, _ = Terminal.size
      @max = Math.min(@lines, rows)
      @max = 1 if @max < 1
      @started = true
      @io << HIDE_CURSOR
      @io.flush
    end

    # Repaint the region. The cursor is assumed to rest at column 0 of the first
    # region row, and is left there again when done.
    def draw(lines : Array(String)) : Nil
      return if @max < 1
      _, cols = Terminal.size
      width = cols > 1 ? cols - 1 : cols

      grow_to Math.min(lines.size, @max)
      return if @height < 1 # nothing to show yet

      visible = lines.last(@height)
      pad = @height - visible.size # blank rows above the content (bottom-aligned)
      last = @height - 1
      sequence = String.build do |str|
        @height.times do |row|
          str << CLEAR_LINE
          content_index = row - pad
          str << prepare(visible[content_index], width) if content_index >= 0
          str << "\r\n" unless row == last
        end
        # Return to the first region row without emitting a newline past the last.
        str << "\e[" << last << 'A' if @height > 1
        str << '\r'
      end
      @io << sequence
      @io.flush
    end

    # Enlarge the reserved region to `target` rows (never shrinks). Each added row
    # is opened by scrolling, which pushes existing content up into scrollback
    # rather than overwriting it. Leaves the cursor at the first region row.
    private def grow_to(target : Int32) : Nil
      return if target <= @height
      if @height == 0
        added = target - 1 # the current cursor line becomes the first row
        if added > 0
          @io << ("\n" * added) << "\e[" << added << 'A'
        end
        @io << '\r'
      else
        added = target - @height
        @io << "\e[" << (@height - 1) << 'B' if @height > 1 # to the last row
        @io << ("\n" * added)                               # open `added` rows below
        @io << "\e[" << (target - 1) << 'A' << '\r'         # back to the first row
      end
      @height = target
    end

    # Move the cursor below the region and show it, so a following shell prompt
    # (or the shell after Ctrl-C) appears after the display rather than on top of
    # it or wherever the cursor happened to rest. Idempotent and safe from an
    # at_exit / signal handler: it runs at most once and swallows a dead terminal.
    def finish : Nil
      return if @done
      @done = true
      return unless @started # never hid the cursor, nothing to restore
      @io << "\e[" << (@height - 1) << 'B' if @height > 1
      @io << "\r\n" if @height > 0 # leave the region on its own lines
      @io << SHOW_CURSOR
      @io.flush
    rescue IO::Error
      # Terminal already gone; nothing to restore.
    end

    # Restore the cursor unconditionally; safe to call from an at_exit hook when
    # no renderer instance is available.
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
