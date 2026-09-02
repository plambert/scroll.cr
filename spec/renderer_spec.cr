require "./spec_helper"

module Scroll
  describe Renderer do
    describe "#draw with a progress line" do
      it "paints the progress text on the bottom row of the region" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 3, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw(["a", "b"], "50% done")
        io.to_s.should contain("a")
        io.to_s.should contain("b")
        # Last row painted, and no newline after it.
        io.to_s.should contain("\e[2K50% done")
        io.to_s.should_not contain("50% done\r\n")
      end

      it "reserves the bottom row, so the tail keeps to the rows above it" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 30, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw((1..40).map(&.to_s), "bar")
        # 23 tail rows plus the bar, on a 24-row terminal.
        io.to_s.scan("\e[2K").size.should eq(24)
        io.to_s.should contain("\e[2Kbar")
      end

      # The progress line is composed to fit and carries its own color escapes,
      # so it goes out as it came rather than through the sanitizer.
      it "writes the progress text through untouched" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 2, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw(["a"], "\e[42m \e[0m 50%")
        io.to_s.should contain("\e[42m \e[0m 50%")
      end
    end

    describe "#draw_progress" do
      it "repaints only the bottom row and leaves the cursor where it was" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 3, progress: true, size: {24, 80})
        renderer.start
        renderer.draw(["a", "b"], "first")
        io.clear
        renderer.draw_progress("second")
        io.to_s.should eq("\e[2B\e[2Ksecond\r\e[2A")
      end

      it "opens a row for the bar when nothing has been drawn yet" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 3, progress: true, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("only")
        io.to_s.should contain("\e[2Konly")
      end

      it "does nothing when the progress line is off" do
        io = IO::Memory.new
        renderer = Renderer.new(io, 3, size: {24, 80})
        renderer.start
        io.clear
        renderer.draw_progress("ignored")
        io.to_s.should be_empty
      end
    end
  end
end
