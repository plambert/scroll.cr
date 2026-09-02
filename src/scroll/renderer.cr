module Scroll
  # Draws the tail window as a fixed-height region on the terminal, repainting it
  # in place each frame. The region is reserved once by scrolling (which pushes
  # any existing screen content up into scrollback rather than overwriting it),
  # and thereafter every frame is a single up-move, N cleared-and-rewritten rows,
  # and a move back to the top. No newline is ever emitted after the last row, so
  # the terminal never scrolls again and the region cannot drift or clobber
  # history. Lines are sanitized and truncated to one short of the terminal width
  # (never touching the last column, which can trigger auto-wrap). The raw stream
  # on STDOUT is never touched by any of this. With `--progress` the bottom row of
  # the region belongs to the progress line, and can be repainted on its own.
  class Renderer
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    CLEAR_LINE  = "\e[2K"

    # `progress` reserves the bottom row of the region for the progress line.
    # `size` overrides the terminal size query (rows, cols); it exists so specs
    # can drive the renderer against an `IO::Memory`, which has no fd.
    def initialize(@io : IO, @lines : Int32, @sanitize : Bool = true,
                   @progress : Bool = false, @size : {Int32, Int32}? = nil)
      @max = 0      # largest height the region may reach (set in #start)
      @height = 0   # rows currently reserved; grows toward @max as lines arrive
      @done = false # guards #finish against running twice
      @started = false
    end

    # Columns a row may use: one short of the terminal width, since writing the
    # last column can trigger auto-wrap.
    def width : Int32
      _, cols = @size || Terminal.size
      cols > 1 ? cols - 1 : cols
    end

    # Hide the cursor and record the ceiling for the region height. The region is
    # not reserved up front: it grows one row at a time as lines arrive, so a
    # short stream never opens more rows than it has lines.
    def start : Nil
      rows, _ = @size || Terminal.size
      rows -= 1 if @progress # the bottom row belongs to the progress line
      @max = Math.min(@lines, rows)
      @max = 1 if @max < 1
      @started = true
      @io << HIDE_CURSOR
      @io.flush
    end

    # Repaint the region. The cursor is assumed to rest at column 0 of the first
    # region row, and is left there again when done.
    def draw(lines : Array(String), progress : String? = nil) : Nil
      return if @max < 1
      row_width = width

      grow_to Math.min(lines.size, @max) + (progress ? 1 : 0)
      return if @height < 1 # nothing to show yet

      content_height = progress ? @height - 1 : @height
      visible = lines.last(content_height)
      pad = content_height - visible.size # blank rows above the content (bottom-aligned)
      last = @height - 1
      sequence = String.build do |str|
        @height.times do |row|
          str << CLEAR_LINE
          if progress && row == last
            str << prepare(progress, row_width)
          else
            content_index = row - pad
            str << prepare(visible[content_index], row_width) if content_index >= 0
          end
          str << "\r\n" unless row == last
        end
        # Return to the first region row without emitting a newline past the last.
        str << "\e[" << last << 'A' if @height > 1
        str << '\r'
      end
      @io << sequence
      @io.flush
    end

    # Repaint only the progress row. Ticks where no new line arrived still move
    # the rates, the ETA, and a scrolling name, and repainting one row instead of
    # the whole region keeps that cheap.
    def draw_progress(text : String) : Nil
      return unless @progress
      return if @max < 1
      grow_to 1 if @height < 1
      last = @height - 1
      sequence = String.build do |str|
        str << "\e[" << last << 'B' if last > 0
        str << CLEAR_LINE << prepare(text, width) << '\r'
        str << "\e[" << last << 'A' if last > 0
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
