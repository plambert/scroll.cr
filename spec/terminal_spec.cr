require "./spec_helper"

module Scroll
  describe Terminal do
    # XTVERSION answers with the terminal's name, which is the only part of the
    # reply that matters: a few terminals show OSC 9;4 progress, and the rest
    # would print the sequence into the display.
    describe ".reports_progress?" do
      it "recognizes the terminals that show it" do
        Terminal.reports_progress?("\eP>|ghostty 1.2.0\e\\").should be_true
        Terminal.reports_progress?("\eP>|kitty(0.42.1)\e\\").should be_true
        Terminal.reports_progress?("\eP>|iTerm2 3.5.11\e\\").should be_true
      end

      it "matches whatever case the terminal answered in" do
        Terminal.reports_progress?("\eP>|Ghostty 1.2.0\e\\").should be_true
        Terminal.reports_progress?("\eP>|KITTY\e\\").should be_true
      end

      it "rejects a terminal that is not one of them" do
        Terminal.reports_progress?("\eP>|XTerm(390)\e\\").should be_false
        Terminal.reports_progress?("\eP>|WezTerm 20240203\e\\").should be_false
      end

      it "rejects silence" do
        Terminal.reports_progress?(nil).should be_false
        Terminal.reports_progress?("").should be_false
      end
    end
  end
end
