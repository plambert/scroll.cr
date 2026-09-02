require "./spec_helper"

# The columns a rendered line occupies, with the color escapes taken back out.
private def visible(text : String) : String
  text.gsub(/\e\[[0-9;]*m/, "")
end

module Scroll
  describe Progress do
    describe ".parse_size" do
      it "reads a bare byte count" do
        Progress.parse_size("1024").should eq(1024)
        Progress.parse_size("100b").should eq(100)
      end

      it "scales suffixes by 1024, case insensitively" do
        Progress.parse_size("1k").should eq(1024)
        Progress.parse_size("1K").should eq(1024)
        Progress.parse_size("1kb").should eq(1024)
        Progress.parse_size("1KiB").should eq(1024)
        Progress.parse_size("2M").should eq(2 * 1024 * 1024)
        Progress.parse_size("1g").should eq(1024_i64 ** 3)
      end

      it "accepts a decimal magnitude" do
        Progress.parse_size("1.1k").should eq(1126)
        Progress.parse_size("2.5M").should eq((2.5 * 1024 * 1024).to_i64)
      end

      it "rejects values that are not a size" do
        expect_raises(ArgumentError, /not a byte size/) { Progress.parse_size("") }
        expect_raises(ArgumentError, /not a byte size/) { Progress.parse_size("big") }
        expect_raises(ArgumentError, /not a byte size/) { Progress.parse_size("-5") }
        expect_raises(ArgumentError, /not a byte size/) { Progress.parse_size("5x") }
      end

      it "rejects a size below one byte" do
        expect_raises(ArgumentError, /at least 1 byte/) { Progress.parse_size("0") }
        expect_raises(ArgumentError, /at least 1 byte/) { Progress.parse_size("0.4") }
      end
    end

    describe ".resolve" do
      it "takes a byte size on its own" do
        total, warnings = Progress.resolve(500_i64, nil, nil)
        total.bytes.should eq(500)
        total.lines.should be_nil
        warnings.should be_empty
      end

      it "takes a line count on its own" do
        total, warnings = Progress.resolve(nil, 40_i64, nil)
        total.lines.should eq(40)
        total.bytes.should be_nil
        warnings.should be_empty
      end

      it "takes a file size when no --size is given" do
        total, warnings = Progress.resolve(nil, nil, 900_i64)
        total.bytes.should eq(900)
        warnings.should be_empty
      end

      # The TODO for this feature is explicit: a byte size and a line count
      # together warn and the byte size wins.
      it "prefers a byte size over a line count, and says so" do
        total, warnings = Progress.resolve(500_i64, 40_i64, nil)
        total.bytes.should eq(500)
        total.lines.should be_nil
        warnings.should eq(["--size-lines ignored; a byte size takes precedence"])
      end

      it "warns for a line count given with a file size too" do
        total, warnings = Progress.resolve(nil, 40_i64, 900_i64)
        total.bytes.should eq(900)
        warnings.should eq(["--size-lines ignored; a byte size takes precedence"])
      end

      it "prefers --size over --file-size, and says so" do
        total, warnings = Progress.resolve(500_i64, nil, 900_i64)
        total.bytes.should eq(500)
        warnings.should eq(["--file-size ignored; --size takes precedence"])
      end

      it "reports an unknown total when nothing is given" do
        total, warnings = Progress.resolve(nil, nil, nil)
        total.known?.should be_false
        warnings.should be_empty
      end
    end

    describe ".human_bytes" do
      it "keeps small values exact and scales larger ones by 1024" do
        Progress.human_bytes(0_i64).should eq("0B")
        Progress.human_bytes(512_i64).should eq("512B")
        Progress.human_bytes(1024_i64).should eq("1.0K")
        Progress.human_bytes(1_260_i64).should eq("1.2K")
        Progress.human_bytes(12_600_i64).should eq("12K")
        Progress.human_bytes(1_300_000_i64).should eq("1.2M")
      end
    end

    describe ".human_count" do
      it "drops the unit letter at the bottom of the scale" do
        Progress.human_count(0_i64).should eq("0")
        Progress.human_count(999_i64).should eq("999")
        Progress.human_count(2_048_i64).should eq("2.0K")
        Progress.human_count(20_480_i64).should eq("20K")
      end
    end

    describe ".duration" do
      it "shows the two largest units that fit" do
        Progress.duration(45.seconds).should eq("45s")
        Progress.duration(121.seconds).should eq("2m01s")
        Progress.duration(3_720.seconds).should eq("1h02m")
        Progress.duration(273_600.seconds).should eq("3d04h")
      end
    end

    describe ".bar" do
      it "fills in proportion to the fraction" do
        Progress.bar(10, 0.0).should eq("░" * 10)
        Progress.bar(10, 0.5).should eq(("█" * 5) + ("░" * 5))
        Progress.bar(10, 1.0).should eq("█" * 10)
      end

      it "clamps a fraction outside 0..1" do
        Progress.bar(4, -1.0).should eq("░" * 4)
        Progress.bar(4, 2.0).should eq("█" * 4)
      end

      it "is empty with no room" do
        Progress.bar(0, 0.5).should eq("")
      end
    end

    describe ".bar with color" do
      # Background colors mean the filled part and the track meet with no gap,
      # which drawing foreground blocks cannot manage.
      it "paints the filled part and the track as backgrounds" do
        bar = Progress.bar(10, 0.5, color: true)
        bar.should contain("\e[#{Progress::FILLED_STYLE}m     \e[0m")
        bar.should contain("\e[#{Progress::TRACK_STYLE}m     \e[0m")
        bar.should_not contain(Progress::EMPTY)
        visible(bar).size.should eq(10)
      end

      it "gives the leading cell an eighth-block for sub-column resolution" do
        bar = Progress.bar(8, 0.5 + 1.0 / 16, color: true) # 4 and a half columns
        bar.should contain("\e[#{Progress::PARTIAL_STYLE}m▌\e[0m")
        visible(bar).size.should eq(8)
      end

      it "stays in ASCII under that charset, still without a gap" do
        bar = Progress.bar(8, 0.5 + 1.0 / 16, color: true, charset: Progress::Charset::Ascii)
        Progress::EIGHTHS.each { |glyph| bar.should_not contain(glyph) }
        visible(bar).size.should eq(8)
      end
    end

    describe ".bar without color" do
      it "falls back to glyphs, with an eighth-block for the partial column" do
        Progress.bar(4, 0.5).should eq("██░░")
        Progress.bar(8, 0.5 + 1.0 / 16).should eq("████▌░░░")
      end

      it "uses ASCII glyphs under that charset" do
        Progress.bar(4, 0.5, charset: Progress::Charset::Ascii).should eq("##--")
        Progress.bar(4, 1.0, charset: Progress::Charset::Ascii).should eq("####")
      end
    end

    describe ".scroll" do
      it "shows a name that fits whole" do
        Progress.scroll("build.log", 20, 0.seconds).should eq("build.log")
      end

      # 2 columns per second, so each half-second step slides one column.
      it "slides a long name at two columns per second" do
        name = "abcdefghij"
        Progress.scroll(name, 4, 0.seconds).should eq("abcd")
        Progress.scroll(name, 4, 500.milliseconds).should eq("bcde")
        Progress.scroll(name, 4, 1.second).should eq("cdef")
        Progress.scroll(name, 4, 3.seconds).should eq("ghij")
      end

      it "holds at the end for a second, then starts over" do
        name = "abcdefghij"
        Progress.scroll(name, 4, 3.seconds).should eq("ghij")   # last window
        Progress.scroll(name, 4, 3.5.seconds).should eq("ghij") # paused
        Progress.scroll(name, 4, 4.seconds).should eq("ghij")   # paused
        Progress.scroll(name, 4, 4.5.seconds).should eq("abcd") # wrapped
      end

      it "is empty with no room" do
        Progress.scroll("build.log", 0, 0.seconds).should eq("")
      end
    end

    describe Progress::Counters do
      it "accumulates bytes and lines" do
        counters = Progress::Counters.new
        counters.add(10, 2)
        counters.add(5, 1)
        counters.bytes.should eq(15)
        counters.lines.should eq(3)
      end

      it "counts newlines in a chunk" do
        Progress::Counters.newlines("a\nb\nc".to_slice).should eq(2)
        Progress::Counters.newlines("".to_slice).should eq(0)
      end
    end

    describe "#render" do
      it "shows bytes, lines, and both rates when the size is unknown" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new, nil, start)
        line = meter.render(80, 2_048_i64, 100_i64, start + 2.seconds)
        line.should eq("2.0K · 100 ln · 1.0K/s · 50 ln/s")
      end

      it "adds a percentage, a bar, and an ETA when the size is known" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), nil, start)
        line = meter.render(80, 2_048_i64, 100_i64, start + 2.seconds)
        line.should start_with(" 50% ")
        line.should contain("2.0K/4.0K")
        line.should contain("eta 2s")
      end

      it "measures against a line total when that is what was given" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(lines: 200_i64), nil, start)
        line = meter.render(80, 2_048_i64, 100_i64, start + 2.seconds)
        line.should start_with(" 50% ")
        line.should contain("100/200 ln")
        line.should contain("eta 2s")
      end

      it "never exceeds the width it is given" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), "a-long-enough-name.log", start)
        (10..120).each do |width|
          meter.render(width, 2_048_i64, 100_i64, start + 1.second).size.should be <= width
        end
      end

      it "shows the whole name while the bar keeps its preferred width" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), "build.log", start)
        line = meter.render(120, 2_048_i64, 100_i64, start + 1.second)
        line.should end_with(" build.log")
        bar_width = line.count(Progress::FILL) + line.count(Progress::EMPTY)
        bar_width.should be >= Progress::PREFERRED_BAR
      end

      it "gives the bar its minimum and the rest to the name when the name is long" do
        start = Time.instant
        name = "/a/very/long/path/that/will/not/fit/anywhere.log"
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), name, start)
        line = meter.render(60, 2_048_i64, 100_i64, start + 1.second)
        bar_width = line.count(Progress::FILL) + line.count(Progress::EMPTY)
        bar_width.should eq(Progress::MINIMUM_BAR)
        line.size.should be <= 60
      end

      it "scrolls a name that cannot fit" do
        start = Time.instant
        name = "/a/very/long/path/that/will/not/fit/anywhere.log"
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), name, start)
        first = meter.render(60, 2_048_i64, 100_i64, start)
        later = meter.render(60, 2_048_i64, 100_i64, start + 2.seconds)
        first.should_not eq(later)
      end

      it "strips control bytes from the name" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new, "we\e[31mird\nname", start)
        meter.render(80, 10_i64, 1_i64, start + 1.second).should contain("we[31mirdname")
      end

      it "drops fields it has no room for, keeping the percentage and the bar" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), nil, start)
        line = meter.render(20, 2_048_i64, 100_i64, start + 1.second)
        line.should start_with(" 50% ")
        line.should_not contain("ln")
        line.size.should be <= 20
      end

      # Rates come from a trailing window, so a stalled stream falls to zero
      # instead of coasting on the average since the start.
      it "falls to a zero rate once the stream stalls past the window" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new, nil, start)
        meter.render(80, 1_024_i64, 10_i64, start + 1.second)
        line = meter.render(80, 1_024_i64, 10_i64, start + 10.seconds)
        line.should contain("0B/s")
        line.should contain("0 ln/s")
      end

      it "colors the name apart from the rest of the line" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), "build.log", start, color: true)
        line = meter.render(120, 2_048_i64, 100_i64, start + 1.second)
        line.should contain("\e[#{Progress::NAME_STYLE}mbuild.log\e[0m")
        line.should contain("\e[#{Progress::PERCENT_STYLE}m")
        line.should contain("\e[#{Progress::SEPARATOR_STYLE}m")
      end

      it "counts only the visible columns when color is on" do
        start = Time.instant
        meter = Progress.new(Progress::Total.new(bytes: 4_096_i64), "build.log", start, color: true)
        (20..120).each do |width|
          visible(meter.render(width, 2_048_i64, 100_i64, start + 1.second)).size.should be <= width
        end
      end

      it "separates the stats with the charset's separator" do
        start = Time.instant
        unicode = Progress.new(Progress::Total.new, nil, start)
        ascii = Progress.new(Progress::Total.new, nil, start, charset: Progress::Charset::Ascii)
        unicode.render(80, 2_048_i64, 100_i64, start + 2.seconds).should contain(" · ")
        ascii.render(80, 2_048_i64, 100_i64, start + 2.seconds).should contain(" | ")
      end

      it "is empty with no room at all" do
        meter = Progress.new(Progress::Total.new)
        meter.render(0, 1_i64, 1_i64).should eq("")
      end
    end
  end
end
