module Scroll
  # Maintains the top-N lines of the stream by the sort order, for --sort mode.
  #
  # Rather than accumulate every line, it keeps at most `capacity` entries, sorted
  # in display order (least-shown first, most-shown last). Each new line is keyed
  # once; when the window is full and the new line is not greater than the current
  # lowest kept entry, it is skipped with a single comparison. Otherwise it
  # replaces the lowest entry and the window is re-sorted. So memory stays bounded
  # at N and the common case (a line that does not make the cut) is O(1).
  #
  # The window's contents are already in display order, so the render path draws
  # `snapshot` directly — no further sorting needed.
  class SortWindow
    NEWLINE = '\n'.ord.to_u8

    record Entry, key : HumanKey, seq : Int64, line : String

    def initialize(@capacity : Int32, @sorter : Sorter)
      @entries = [] of Entry
      @line = IO::Memory.new
      @seq = 0_i64
    end

    # Feed a chunk of raw bytes; each complete line is offered to the window.
    def feed(bytes : Bytes) : Nil
      position = 0
      while newline = bytes.index(NEWLINE, position)
        @line.write bytes[position...newline]
        offer String.new(@line.to_slice)
        @line.clear
        position = newline + 1
      end
      @line.write bytes[position..] if position < bytes.size
    end

    # At EOF, optionally offer a trailing newline-less line (the --final option).
    def finalize(include_trailing : Bool = false) : Nil
      return unless include_trailing
      remainder = @line.to_slice
      return if remainder.empty?
      offer String.new(remainder)
      @line.clear
    end

    # The kept lines in display order (least-shown first). Size is at most N.
    def snapshot : Array(String)
      @entries.map(&.line)
    end

    def size : Int32
      @entries.size
    end

    private def offer(line : String) : Nil
      @seq += 1
      entry = Entry.new(@sorter.key(line), @seq, line)
      if @entries.size < @capacity
        insert_sorted entry
      elsif compare(entry, @entries.first) > 0
        # Greater than the lowest kept entry: it belongs in the window.
        @entries.shift
        insert_sorted entry
      end
      # Otherwise the window is full and this line does not make the cut: skip it.
    end

    private def insert_sorted(entry : Entry) : Nil
      @entries << entry
      @entries.sort! { |a, b| compare(a, b) }
    end

    # Display-order comparison: by key, inverted under --reverse, with the
    # insertion sequence as a stable tiebreak (earlier lines first, matching the
    # Sorter's stable ordering).
    private def compare(a : Entry, b : Entry) : Int32
      cmp = a.key <=> b.key
      cmp = -cmp if @sorter.reverse?
      cmp.zero? ? (a.seq <=> b.seq) : cmp
    end
  end
end
