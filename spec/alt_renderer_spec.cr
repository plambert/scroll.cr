require "./spec_helper"

# Feed a String as a chunk beginning at `start`.
private def feed_chunk(renderer : Scroll::AltRenderer, text : String, start : Int64) : Nil
  renderer.feed(text.to_slice, start)
end

module Scroll
  describe AltRenderer do
    describe "#start" do
      it "enters the alt screen and hides the cursor in full mode" do
        io = IO::Memory.new
        AltRenderer.new(io, 5, region: false, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[H")
      end

      it "sets a DECSTBM band of min(N, rows) and parks the cursor in region mode" do
        io = IO::Memory.new
        AltRenderer.new(io, 5, region: true, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[1;5r\e[5;1H")
      end

      it "clamps the band to the terminal height when N exceeds it" do
        io = IO::Memory.new
        AltRenderer.new(io, 100, region: true, size: {24, 80}).start
        io.to_s.should end_with("\e[2J\e[1;24r\e[24;1H")
      end
    end

    describe "#start with a progress line" do
      it "keeps the bottom row out of the band in region mode" do
        io = IO::Memory.new
        AltRenderer.new(io, 5, region: true, progress: true, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[1;5r\e[5;1H")
      end

      it "clamps the band to one row short of the terminal in region mode" do
        io = IO::Memory.new
        AltRenderer.new(io, 100, region: true, progress: true, size: {24, 80}).start
        io.to_s.should end_with("\e[2J\e[1;23r\e[23;1H")
      end

      # Full mode normally sets no region at all; a progress line needs one, or
      # the bottom row scrolls away with everything else.
      it "sets a band of every row but the last in full mode" do
        io = IO::Memory.new
        AltRenderer.new(io, 5, region: false, progress: true, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[1;23r\e[23;1H")
      end
    end

    describe "#draw_progress" do
      it "paints the bottom row and restores the cursor" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("50% done")
        io.to_s.should eq("\e7\e[24;1H\e[2K50% done\e8")
      end

      it "truncates the text to the terminal width" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, progress: true, size: {24, 10})
        renderer.start
        io.clear
        renderer.draw_progress("0123456789abcdef")
        io.to_s.should contain("\e[2K012345678\e8")
      end

      it "does nothing when the progress line is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("ignored")
        io.to_s.should be_empty
      end
    end

    describe "#feed and #flush" do
      it "writes each complete line terminated by CRLF" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb\nc\n", 0_i64)
        renderer.flush
        io.to_s.should eq("a\r\nb\r\nc\r\n")
      end

      it "withholds a trailing partial line until its newline arrives" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb\npartial", 0_i64)
        renderer.flush
        io.to_s.should eq("a\r\nb\r\n")
        io.clear
        feed_chunk(renderer, "-end\n", 11_i64)
        renderer.flush
        io.to_s.should eq("partial-end\r\n")
      end

      it "does nothing when there is nothing pending" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.flush
        io.to_s.should be_empty
      end

      it "truncates lines to one short of the terminal width" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 10})
        renderer.start
        io.clear
        feed_chunk(renderer, "abcdefghijklmno\n", 0_i64)
        renderer.flush
        io.to_s.should eq("abcdefghi\r\n") # 9 chars (cols - 1), then CRLF
      end

      it "strips control bytes unless sanitize is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\eb\tc\n", 0_i64)
        renderer.flush
        io.to_s.should eq("ab c\r\n") # ESC dropped, tab -> space
      end

      it "keeps control bytes when sanitize is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, sanitize: false, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\tb\n", 0_i64)
        renderer.flush
        io.to_s.should eq("a\tb\r\n")
      end

      it "emits only the last `height` lines when more than a bandful is pending" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 3, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n5\n", 0_i64)
        renderer.flush
        io.to_s.should eq("3\r\n4\r\n5\r\n") # band is 3 rows; earlier lines scroll off
      end
    end

    describe "gap handling" do
      it "skips the post-gap fragment up to the next newline" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "one\ntwo\n", 0_i64) # ends at offset 8
        # A gap: next chunk starts at 20, not 8. Its leading fragment is the tail
        # of a dropped line and must be discarded up to the newline.
        feed_chunk(renderer, "gment\nthree\n", 20_i64)
        renderer.flush
        io.to_s.should eq("one\r\ntwo\r\nthree\r\n")
      end
    end

    describe "#notify_resize" do
      it "re-applies the region on the next flush in region mode" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\n", 0_i64)
        renderer.notify_resize
        renderer.flush
        io.to_s.should eq("\e[2J\e[1;5r\e[5;1Ha\r\n")
      end

      it "does not emit region escapes in full mode" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 5, region: false, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\n", 0_i64)
        renderer.notify_resize
        renderer.flush
        io.to_s.should eq("a\r\n")
      end
    end

    describe ".restore" do
      it "shows the cursor, resets the region, and leaves the alt screen" do
        io = IO::Memory.new
        AltRenderer.restore(io)
        io.to_s.should eq("\e[?25h\e[r\e[?1049l")
      end

      it "is a safe no-op sequence even when start never ran" do
        io = IO::Memory.new
        AltRenderer.restore(io)
        io.to_s.should eq("\e[?25h\e[r\e[?1049l")
      end
    end

    describe "#finish" do
      it "drains, restores the screen, then echoes the recent tail" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 3, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n", 0_i64)
        renderer.finish(false)
        # last-flush of the band, then restore, then the echo of the last 3 lines.
        io.to_s.should eq("2\r\n3\r\n4\r\n\e[?25h\e[r\e[?1049l2\r\n3\r\n4\r\n")
      end

      it "promotes a trailing newline-less line when final is set" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 3, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb", 0_i64)
        renderer.finish(true)
        io.to_s.should eq("a\r\nb\r\n\e[?25h\e[r\e[?1049la\r\nb\r\n")
      end

      it "omits a trailing newline-less line when final is not set" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, 3, region: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb", 0_i64)
        renderer.finish(false)
        io.to_s.should eq("a\r\n\e[?25h\e[r\e[?1049la\r\n")
      end
    end
  end
end
