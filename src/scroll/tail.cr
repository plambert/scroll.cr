module Scroll
  # Maintains the last N *complete* lines of a byte stream, fed in arbitrary
  # chunks, guaranteeing the displayed window is always N (or fewer) genuinely
  # contiguous complete lines — never a partial line and never a splice across a
  # gap.
  #
  # Each chunk is tagged with the byte offset at which it begins. If a chunk's
  # start offset does not equal the end offset of the previous chunk, the pump
  # dropped one or more chunks (STDERR could not keep up). Two things then follow:
  #
  # * The bytes immediately after a gap are the tail of a line whose head was
  #   dropped. They are skipped up to and including the next newline, so that
  #   truncated line is never shown.
  # * The visible window is *frozen* on its last good contents while a fresh
  #   segment is rebuilt from the post-gap lines. Only once the new segment holds
  #   a full window does it replace the visible one. This keeps the display on a
  #   valid contiguous window at all times (jumping forward when it can) instead
  #   of blanking out and refilling on every drop.
  class Tail
    NEWLINE = '\n'.ord.to_u8

    getter capacity : Int32

    def initialize(@capacity : Int32)
      raise ArgumentError.new "capacity must be >= 1" if @capacity < 1
      @shown = Deque(String).new    # the window currently displayed
      @building = Deque(String).new # a fresh segment accumulating after a gap
      @rebuilding = false
      @skip_fragment = false # discard bytes up to the next newline after a gap
      @line = IO::Memory.new
      @expected_offset = nil.as(Int64?)
    end

    # Feed a chunk of raw bytes that begins at byte `start` in the stream.
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

    # Promote a trailing newline-less line to a complete line, then reveal any
    # partially-rebuilt segment. Call once at EOF when the caller wants the final
    # unterminated line included.
    def finalize : Nil
      remainder = @line.to_slice
      unless remainder.empty? || @skip_fragment
        push String.new(remainder)
        @line.clear
      end
      reveal_building unless @building.empty?
    end

    # The current retained lines, oldest first. Always a contiguous suffix of some
    # complete-line run in the stream.
    def snapshot : Array(String)
      @shown.to_a
    end

    def size : Int32
      @shown.size
    end

    private def begin_gap : Nil
      @rebuilding = true
      @building.clear
      @line.clear           # discard the partial head we were assembling
      @skip_fragment = true # and discard the interrupted line's tail
    end

    private def push(line : String) : Nil
      if @rebuilding
        @building.push line
        @building.shift if @building.size > @capacity
        reveal_building if @building.size >= @capacity
      else
        @shown.push line
        @shown.shift if @shown.size > @capacity
      end
    end

    private def reveal_building : Nil
      @shown = @building
      @building = Deque(String).new
      @rebuilding = false
    end
  end
end
