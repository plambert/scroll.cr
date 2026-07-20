require "./spec_helper"

# Feed a String as a chunk beginning at `start`.
private def feed_chunk(tail : Scroll::Tail, text : String, start : Int64) : Nil
  tail.tail_feed(text, start)
end

module Scroll
  class Tail
    # Test helper: feed a String and return the byte offset just past it.
    def tail_feed(text : String, start : Int64) : Nil
      feed(text.to_slice, start)
    end
  end

  describe Tail do
    it "keeps the last N complete lines" do
      tail = Tail.new(3)
      feed_chunk(tail, "1\n2\n3\n4\n5\n", 0_i64)
      tail.snapshot.should eq(["3", "4", "5"])
    end

    it "ignores an in-progress line with no newline yet" do
      tail = Tail.new(3)
      feed_chunk(tail, "1\n2\npartial", 0_i64)
      tail.snapshot.should eq(["1", "2"])
    end

    it "carries a partial line across contiguous chunk boundaries" do
      tail = Tail.new(3)
      feed_chunk(tail, "ab", 0_i64)
      tail.snapshot.should be_empty
      feed_chunk(tail, "c\n", 2_i64)
      tail.snapshot.should eq(["abc"])
    end

    it "freezes the window on a gap until a fresh full window is rebuilt" do
      tail = Tail.new(3)
      feed_chunk(tail, "1\n2\n3\n", 0_i64) # ends at offset 6; window [1,2,3]
      tail.snapshot.should eq(["1", "2", "3"])

      # Gap at offset 100. The leading "TAIL" is the dropped line's remainder and
      # must be discarded; b and c begin a new segment that is not yet full.
      feed_chunk(tail, "TAIL\nb\nc\n", 100_i64)
      tail.snapshot.should eq(["1", "2", "3"]) # frozen on the last good window

      feed_chunk(tail, "d\n", 109_i64) # new segment [b,c,d] fills -> revealed
      tail.snapshot.should eq(["b", "c", "d"])
    end

    it "never splices a pre-gap partial onto post-gap bytes" do
      tail = Tail.new(2)
      feed_chunk(tail, "x\ny\nab", 0_i64) # window [x,y]; "ab" is a partial head
      tail.snapshot.should eq(["x", "y"])

      # "ab" + dropped bytes + "c" would be one line: "c" is discarded, never "abc".
      feed_chunk(tail, "c\nd\ne\n", 100_i64) # d,e form the new segment (cap 2) -> revealed
      tail.snapshot.should eq(["d", "e"])
      tail.snapshot.should_not contain("abc")
    end

    it "includes a trailing newline-less line only after finalize" do
      tail = Tail.new(3)
      feed_chunk(tail, "1\n2\ntail", 0_i64)
      tail.snapshot.should eq(["1", "2"])
      tail.finalize
      tail.snapshot.should eq(["1", "2", "tail"])
    end

    it "reveals a partial rebuilt segment on finalize" do
      tail = Tail.new(5)
      feed_chunk(tail, "1\n2\n3\n4\n5\n", 0_i64)
      feed_chunk(tail, "TAIL\nb\nc\n", 100_i64) # segment [b,c] never fills to 5
      tail.snapshot.should eq(["1", "2", "3", "4", "5"])
      tail.finalize
      tail.snapshot.should eq(["b", "c"])
    end

    it "handles a chunk split across a newline run" do
      tail = Tail.new(4)
      feed_chunk(tail, "a\nb\n", 0_i64)
      feed_chunk(tail, "c\nd\n", 4_i64)
      tail.snapshot.should eq(["a", "b", "c", "d"])
    end
  end
end
