require "./spec_helper"

module Scroll
  # Convenience: build a Sorter and order the given lines.
  def self.order(lines, sort = false, reverse = false, human = false, sort_by : SortKey? = nil)
    Sorter.new(sort, reverse, human, sort_by).order(lines)
  end

  describe Sorter do
    describe "identity / no-op" do
      it "returns the same array object when no ordering is requested" do
        lines = ["b", "a", "c"]
        Sorter.new(false, false, false, nil).order(lines).should be(lines)
      end
    end

    describe "lexical sort" do
      it "sorts ascending by byte order" do
        Scroll.order(["banana", "apple", "cherry"], sort: true)
          .should eq(["apple", "banana", "cherry"])
      end

      it "reverses the key comparison with --reverse (descending)" do
        Scroll.order(["apple", "banana", "cherry"], sort: true, reverse: true)
          .should eq(["cherry", "banana", "apple"])
      end

      it "keeps input order for equal keys (stable, ascending)" do
        # Sort by the first column; the "x" rows tie and must keep input order.
        lines = ["x 1", "x 2", "a 0", "x 3"]
        Scroll.order(lines, sort: true, sort_by: SortKey::Field.new(1))
          .should eq(["a 0", "x 1", "x 2", "x 3"])
      end

      it "keeps input order for equal keys under --reverse (stable ties)" do
        lines = ["x 1", "x 2", "a 0", "x 3"]
        Scroll.order(lines, sort: true, reverse: true, sort_by: SortKey::Field.new(1))
          .should eq(["x 1", "x 2", "x 3", "a 0"])
      end
    end

    describe "--reverse without --sort" do
      it "reverses input order (newest at top)" do
        Scroll.order(["one", "two", "three"], reverse: true)
          .should eq(["three", "two", "one"])
      end
    end

    describe "--sort-by integer column" do
      it "sorts on the Nth whitespace field" do
        lines = ["alice 30", "bob 25", "carol 40"]
        Scroll.order(lines, sort: true, sort_by: SortKey::Field.new(2))
          .should eq(["bob 25", "alice 30", "carol 40"])
      end

      it "sends out-of-range and empty fields to the front (empty key)" do
        lines = ["has two", "single", "also two"]
        # column 2 missing on "single" -> empty key sorts first; the two "two"
        # keys tie and keep input order (has before also).
        Scroll.order(lines, sort: true, sort_by: SortKey::Field.new(2))
          .should eq(["single", "has two", "also two"])
      end

      it "splits leading-whitespace lines correctly" do
        lines = ["   zebra x", "apple y"]
        Scroll.order(lines, sort: true, sort_by: SortKey::Field.new(1))
          .should eq(["apple y", "   zebra x"])
      end
    end

    describe "--sort-by /regex/" do
      it "uses the named `sort` capture when present" do
        pattern = SortKey::Pattern.new(/id=(?<sort>\d+)/)
        lines = ["req id=30 ok", "req id=10 ok", "req id=20 ok"]
        Scroll.order(lines, sort: true, human: true, sort_by: pattern)
          .should eq(["req id=10 ok", "req id=20 ok", "req id=30 ok"])
      end

      it "uses the first capture group when there is no named group" do
        pattern = SortKey::Pattern.new(/\[(\w+)\]/)
        lines = ["[c] third", "[a] first", "[b] second"]
        Scroll.order(lines, sort: true, sort_by: pattern)
          .should eq(["[a] first", "[b] second", "[c] third"])
      end

      it "uses the whole match when the pattern has no groups" do
        pattern = SortKey::Pattern.new(/[a-z]+/)
        lines = ["9 cat", "1 ant", "5 bee"]
        Scroll.order(lines, sort: true, sort_by: pattern)
          .should eq(["1 ant", "5 bee", "9 cat"])
      end

      it "collapses non-matching lines to the empty key, keeping input order" do
        pattern = SortKey::Pattern.new(/id=(\d+)/)
        lines = ["no match A", "id=2 b", "no match B", "id=1 a"]
        # Non-matching lines share the empty key; among themselves and vs the
        # empty-keyed group they keep input order and sort first (lexically "").
        Scroll.order(lines, sort: true, sort_by: pattern)
          .should eq(["no match A", "no match B", "id=1 a", "id=2 b"])
      end

      it "combines with --human to sort by the captured token's value" do
        pattern = SortKey::Pattern.new(%r{size=(?<sort>[\d.]+[kKmMgGtT]?B?)})
        lines = ["size=1k a", "size=512B b", "size=1M c", "size=2g d"]
        Scroll.order(lines, sort: true, human: true, sort_by: pattern)
          .should eq(["size=512B b", "size=1k a", "size=1M c", "size=2g d"])
      end
    end

    describe "--human numeric ordering" do
      it "orders plain integers by value, not lexically" do
        Scroll.order(["10", "9", "100", "2"], sort: true, human: true)
          .should eq(["2", "9", "10", "100"])
      end

      it "orders byte suffixes by expanded value (base 1024)" do
        Scroll.order(["1k", "512B", "1M", "2g", "1.5k"], sort: true, human: true)
          .should eq(["512B", "1k", "1.5k", "1M", "2g"])
      end

      it "asserts base 1024: 1k (1024) sorts above 1000" do
        Scroll.order(["1k", "1000", "1025"], sort: true, human: true)
          .should eq(["1000", "1k", "1025"])
      end

      it "treats 2k == 2kB == 2Kb (tie keeps input order)" do
        Scroll.order(["2kB", "2Kb", "2k"], sort: true, human: true)
          .should eq(["2kB", "2Kb", "2k"])
      end

      it "orders floats and ints together" do
        Scroll.order(["1.5", "1", "2"], sort: true, human: true)
          .should eq(["1", "1.5", "2"])
      end

      it "orders negatives below positives" do
        Scroll.order(["-5", "3", "-1.5", "0"], sort: true, human: true)
          .should eq(["-5", "-1.5", "0", "3"])
      end

      it "never treats a byte token as negative (a-5k parses positive 5)" do
        # HUMAN fails (lookbehind), FLOAT fails (no dot); the embedded `-` is a
        # separator, so INT parses `5`, ranking a-5k just above 4 and below 6.
        Scroll.order(["a-5k", "6", "4"], sort: true, human: true)
          .should eq(["4", "a-5k", "6"])
      end

      it "takes the leftmost numeric token, precedence human > float > int" do
        # `1.5k` -> bytes (1536), not the float 1.5 or int 1.
        Scroll.order(["1.5k", "1000", "2000"], sort: true, human: true)
          .should eq(["1000", "1.5k", "2000"])
      end

      it "uses the leftmost int in a sentence (err 3 of 10 -> key 3)" do
        Scroll.order(["err 3 of 10", "err 1 of 10", "err 2 of 10"], sort: true, human: true)
          .should eq(["err 1 of 10", "err 2 of 10", "err 3 of 10"])
      end
    end

    describe "--human mixed numeric / non-numeric" do
      it "groups non-numeric lines before numeric (ascending), lexical among themselves" do
        lines = ["10", "zebra", "2", "apple"]
        Scroll.order(lines, sort: true, human: true)
          .should eq(["apple", "zebra", "2", "10"])
      end

      it "flips the grouping under --reverse" do
        lines = ["10", "zebra", "2", "apple"]
        Scroll.order(lines, sort: true, reverse: true, human: true)
          .should eq(["10", "2", "zebra", "apple"])
      end
    end
  end
end
