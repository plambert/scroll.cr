module Scroll
  # Maintains the last N *complete* lines of a byte stream, fed in arbitrary
  # chunks, while guaranteeing that the retained lines are always a contiguous
  # suffix of the stream.
  #
  # Each chunk is tagged with the byte offset at which it begins. If a chunk's
  # start offset does not equal the end offset of the previous chunk, the pump
  # dropped one or more chunks (STDERR could not keep up). In that case the ring
  # is cleared and any partially-assembled line is discarded, so a pre-gap line
  # is never shown adjacent to a post-gap line. The window then refills from the
  # new segment forward.
  class Tail
    NEWLINE = '\n'.ord.to_u8

    getter capacity : Int32

    def initialize(@capacity : Int32)
      raise ArgumentError.new "capacity must be >= 1" if @capacity < 1
      @lines = Deque(String).new
      @line = IO::Memory.new
      @expected_offset = nil.as(Int64?)
    end

    # Feed a chunk of raw bytes that begins at byte `start` in the stream.
    def feed(bytes : Bytes, start : Int64) : Nil
      if expected = @expected_offset
        reset unless start == expected
      end
      @expected_offset = start + bytes.size

      position = 0
      while newline = bytes.index(NEWLINE, position)
        @line.write bytes[position...newline]
        push String.new(@line.to_slice)
        @line.clear
        position = newline + 1
      end
      @line.write bytes[position..] if position < bytes.size
    end

    # Promote a trailing newline-less line to a complete line. Call once at EOF
    # when the caller wants the final unterminated line included.
    def finalize : Nil
      remainder = @line.to_slice
      return if remainder.empty?
      push String.new(remainder)
      @line.clear
    end

    # The current retained lines, oldest first. Always a contiguous suffix of the
    # complete-line stream.
    def snapshot : Array(String)
      @lines.to_a
    end

    def size : Int32
      @lines.size
    end

    private def push(line : String) : Nil
      @lines.push line
      @lines.shift if @lines.size > @capacity
    end

    private def reset : Nil
      @lines.clear
      @line.clear
    end
  end
end
