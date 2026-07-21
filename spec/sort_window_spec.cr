require "./spec_helper"

private def feed_lines(window : Scroll::SortWindow, *lines : String) : Nil
  lines.each { |line| window.feed("#{line}\n".to_slice) }
end

module Scroll
  describe SortWindow do
    it "keeps the top-N largest across the whole stream, not the last N" do
      sorter = Sorter.new(sort: true, reverse: false, human: false, sort_by: nil)
      window = SortWindow.new(3, sorter)
      # Lexical sort: "1".."9"; the top 3 must be 7,8,9 even though 1,2,3 arrive last.
      feed_lines(window, "9", "8", "7", "6", "5", "4", "3", "2", "1")
      window.snapshot.should eq(["7", "8", "9"])
    end

    it "skips a new line that does not beat the lowest kept entry when full" do
      sorter = Sorter.new(sort: true, reverse: false, human: false, sort_by: nil)
      window = SortWindow.new(2, sorter)
      feed_lines(window, "5", "8") # window full: [5, 8]
      feed_lines(window, "3")      # 3 < 5 (lowest kept) -> skipped
      window.snapshot.should eq(["5", "8"])
      feed_lines(window, "7") # 7 > 5 -> displaces 5
      window.snapshot.should eq(["7", "8"])
    end

    it "orders by human size so the largest are on top" do
      sorter = Sorter.new(sort: true, reverse: false, human: true, sort_by: nil)
      window = SortWindow.new(3, sorter)
      feed_lines(window, "4.0K a", "1.2G b", "512M c", "2.0K d", "8.0G e", "16K f")
      # Top 3 by size: 512M, 1.2G, 8.0G, in ascending display order (largest last).
      window.snapshot.should eq(["512M c", "1.2G b", "8.0G e"])
    end

    it "reverse keeps the smallest N instead" do
      sorter = Sorter.new(sort: true, reverse: true, human: true, sort_by: nil)
      window = SortWindow.new(2, sorter)
      feed_lines(window, "4.0K a", "1.2G b", "512M c", "2.0K d")
      # Smallest two kept; descending display order (smallest at the bottom row),
      # matching Sorter#order(all).last(N) for --reverse.
      window.snapshot.should eq(["4.0K a", "2.0K d"])
    end

    it "sorts by a --sort-by column" do
      sorter = Sorter.new(sort: true, reverse: false, human: true, sort_by: SortKey::Field.new(1))
      window = SortWindow.new(2, sorter)
      feed_lines(window, "30 c", "10 a", "20 b")
      window.snapshot.should eq(["20 b", "30 c"])
    end

    it "keeps fewer than N when the stream is short" do
      sorter = Sorter.new(sort: true, reverse: false, human: false, sort_by: nil)
      window = SortWindow.new(5, sorter)
      feed_lines(window, "b", "a")
      window.snapshot.should eq(["a", "b"])
    end
  end
end
