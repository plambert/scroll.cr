require "./spec_helper"

# Feed a String as a chunk beginning at `start`.
private def feed_chunk(tail : Scroll::Tail, text : String, start : Int64) : Nil
  tail.feed(text.to_slice, start)
end

module Scroll
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

    it "resets to a contiguous suffix when a chunk was dropped (offset gap)" do
      tail = Tail.new(5)
      feed_chunk(tail, "1\n2\n3\n", 0_i64) # ends at offset 6
      tail.snapshot.should eq(["1", "2", "3"])
      feed_chunk(tail, "7\n8\n", 100_i64) # gap: 100 != 6
      # Lines 4..6 were dropped; showing [3,7,8] would be non-contiguous, so the
      # window resets and shows only the new contiguous segment.
      tail.snapshot.should eq(["7", "8"])
    end

    it "discards a pre-gap partial line rather than splicing it onto post-gap bytes" do
      tail = Tail.new(3)
      feed_chunk(tail, "ab", 0_i64)   # partial 'ab', no newline
      feed_chunk(tail, "c\n", 50_i64) # gap: 50 != 2
      tail.snapshot.should eq(["c"])  # never "abc"
    end

    it "includes a trailing newline-less line only after finalize" do
      tail = Tail.new(3)
      feed_chunk(tail, "1\n2\ntail", 0_i64)
      tail.snapshot.should eq(["1", "2"])
      tail.finalize
      tail.snapshot.should eq(["1", "2", "tail"])
    end

    it "handles a chunk split across a newline run" do
      tail = Tail.new(4)
      feed_chunk(tail, "a\nb\n", 0_i64)
      feed_chunk(tail, "c\nd\n", 4_i64)
      tail.snapshot.should eq(["a", "b", "c", "d"])
    end
  end
end
