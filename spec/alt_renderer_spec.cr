require "./spec_helper"

# Feed a String as a chunk beginning at `start`.
private def feed_chunk(renderer : Scroll::AltRenderer, text : String, start : Int64) : Nil
  renderer.feed(text.to_slice, start)
end

module Scroll
  describe AltRenderer do
    describe "#start" do
      it "enters the alt screen, hides the cursor, and takes the whole screen" do
        io = IO::Memory.new
        AltRenderer.new(io, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[H")
      end

      # The band is what keeps the bar's row from scrolling away with the output.
      it "sets a band of every row but the last with a progress line" do
        io = IO::Memory.new
        AltRenderer.new(io, progress: true, size: {24, 80}).start
        io.to_s.should eq("\e[?1049h\e[?25l\e[2J\e[1;23r\e[23;1H")
      end
    end

    describe "#draw_progress" do
      it "paints the bottom row and restores the cursor" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("50% done")
        io.to_s.should eq("\e7\e[24;1H50% done\e[K\e8")
      end

      # The progress line is composed to fit and carries its own color escapes,
      # so it goes out as it came rather than through the sanitizer.
      it "writes the text through untouched" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("\e[42m \e[0m 50%")
        io.to_s.should contain("\e[42m \e[0m 50%")
      end

      it "does nothing when the progress line is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("ignored")
        io.to_s.should be_empty
      end
    end

    describe "#feed and #flush" do
      # A terminating newline would leave the cursor on a blank bottom row, which
      # flickers once a frame under a fast stream.
      it "separates lines with CRLF, leaving the newest one on the cursor row" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb\nc\n", 0_i64)
        renderer.flush
        io.to_s.should eq("a\r\nb\r\nc")
      end

      it "withholds a trailing partial line until its newline arrives" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb\npartial", 0_i64)
        renderer.flush
        io.to_s.should eq("a\r\nb")
        io.clear
        feed_chunk(renderer, "-end\n", 11_i64)
        renderer.flush
        io.to_s.should eq("\r\npartial-end")
      end

      it "does nothing when there is nothing pending" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        renderer.flush
        io.to_s.should be_empty
      end

      it "truncates lines to one short of the terminal width" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 10})
        renderer.start
        io.clear
        feed_chunk(renderer, "abcdefghijklmno\n", 0_i64)
        renderer.flush
        io.to_s.should eq("abcdefghi") # 9 chars (cols - 1)
      end

      it "strips control bytes unless sanitize is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\eb\tc\n", 0_i64)
        renderer.flush
        io.to_s.should eq("ab c") # ESC dropped, tab -> space
      end

      it "keeps control bytes when sanitize is off" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, sanitize: false, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\tb\n", 0_i64)
        renderer.flush
        io.to_s.should eq("a\tb")
      end

      it "emits only the last screenful when more than that is pending" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {3, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n5\n", 0_i64)
        renderer.flush
        io.to_s.should eq("3\r\n4\r\n5") # 3 rows; earlier lines scroll off
      end
    end

    describe "gap handling" do
      it "skips the post-gap fragment up to the next newline" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "one\ntwo\n", 0_i64) # ends at offset 8
        # A gap: next chunk starts at 20, not 8. Its leading fragment is the tail
        # of a dropped line and must be discarded up to the newline.
        feed_chunk(renderer, "gment\nthree\n", 20_i64)
        renderer.flush
        io.to_s.should eq("one\r\ntwo\r\nthree")
      end
    end

    describe "#notify_resize" do
      it "re-applies the band on the next flush when a progress line holds a row" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, progress: true, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\n", 0_i64)
        renderer.notify_resize
        renderer.flush
        io.to_s.should eq("\e[2J\e[1;23r\e[23;1Ha")
      end

      it "emits no region escapes without a progress line" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\n", 0_i64)
        renderer.notify_resize
        renderer.flush
        io.to_s.should eq("a")
      end
    end

    describe ".restore" do
      it "shows the cursor, resets the region, and leaves the alt screen" do
        io = IO::Memory.new
        AltRenderer.restore(io)
        io.to_s.should eq("\e[?25h\e[r\e[?1049l")
      end
    end

    describe "#finish" do
      # The alt screen vanishes by default: the run leaves the terminal as it
      # found it.
      it "drains and restores the screen, leaving nothing behind" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n", 0_i64)
        renderer.finish(false)
        io.to_s.should eq("1\r\n2\r\n3\r\n4\e[?25h\e[r\e[?1049l")
      end

      it "echoes the last -N lines under --leave" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, leave_lines: 10, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n", 0_i64)
        renderer.finish(false)
        io.to_s.should eq("1\r\n2\r\n3\e[?25h\e[r\e[?1049l1\r\n2\r\n3\r\n")
      end

      # -N is what --leave leaves behind, not the screenful the display showed.
      it "echoes no more than -N lines, whatever the screen held" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, leave_lines: 2, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n", 0_i64)
        renderer.finish(false)
        io.to_s.should end_with("\e[?1049l3\r\n4\r\n")
      end

      it "echoes more than the screen showed at once when -N asks for it" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, leave_lines: 4, size: {2, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "1\n2\n3\n4\n", 0_i64)
        renderer.finish(false)
        io.to_s.should end_with("\e[?1049l1\r\n2\r\n3\r\n4\r\n")
      end

      it "promotes a trailing newline-less line when final is set" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, leave_lines: 10, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb", 0_i64)
        renderer.finish(true)
        io.to_s.should eq("a\r\nb\e[?25h\e[r\e[?1049la\r\nb\r\n")
      end

      it "omits a trailing newline-less line when final is not set" do
        io = IO::Memory.new
        renderer = AltRenderer.new(io, leave_lines: 10, size: {24, 80})
        renderer.start
        io.clear
        feed_chunk(renderer, "a\nb", 0_i64)
        renderer.finish(false)
        io.to_s.should eq("a\e[?25h\e[r\e[?1049la\r\n")
      end
    end
  end
end
