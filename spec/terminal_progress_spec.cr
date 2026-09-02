require "./spec_helper"

module Scroll
  describe TerminalProgress do
    describe "#report" do
      it "sends a percentage as OSC 9;4 state 1" do
        io = IO::Memory.new
        TerminalProgress.new(io).report(0.5)
        io.to_s.should eq("\e]9;4;1;50\a")
      end

      it "sends state 3 when the run has no size to measure against" do
        io = IO::Memory.new
        TerminalProgress.new(io).report(nil)
        io.to_s.should eq("\e]9;4;3;0\a")
      end

      it "clamps a fraction outside 0..1" do
        io = IO::Memory.new
        terminal = TerminalProgress.new(io)
        terminal.report(-0.5)
        terminal.report(2.0)
        io.to_s.should eq("\e]9;4;1;0\a\e]9;4;1;100\a")
      end

      # The display ticks 25 times a second; the indicator moves in whole
      # percent, so most of those ticks have nothing new to say.
      it "says nothing when the whole percent has not changed" do
        io = IO::Memory.new
        terminal = TerminalProgress.new(io)
        terminal.report(0.500)
        terminal.report(0.502)
        terminal.report(0.51)
        io.to_s.should eq("\e]9;4;1;50\a\e]9;4;1;51\a")
      end
    end

    describe "#clear" do
      it "takes the indicator away once something was reported" do
        io = IO::Memory.new
        terminal = TerminalProgress.new(io)
        terminal.report(0.5)
        io.clear
        terminal.clear
        io.to_s.should eq("\e]9;4;0;0\a")
      end

      it "says nothing when there was never an indicator" do
        io = IO::Memory.new
        TerminalProgress.new(io).clear
        io.to_s.should be_empty
      end

      it "is safe to call twice" do
        io = IO::Memory.new
        terminal = TerminalProgress.new(io)
        terminal.report(0.5)
        terminal.clear
        io.clear
        terminal.clear
        io.to_s.should be_empty
      end
    end
  end
end
