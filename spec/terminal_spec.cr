require "./spec_helper"

module Scroll
  describe Terminal do
    describe ".scroll_region_supported?" do
      # Save and restore $TERM around each case so the suite is order-independent.
      it "is true for a normal terminal" do
        with_term("xterm-256color") { Terminal.scroll_region_supported?.should be_true }
      end

      it "is false for a dumb terminal" do
        with_term("dumb") { Terminal.scroll_region_supported?.should be_false }
      end

      it "is false when TERM is empty" do
        with_term("") { Terminal.scroll_region_supported?.should be_false }
      end

      it "is false when TERM is unset" do
        with_term(nil) { Terminal.scroll_region_supported?.should be_false }
      end
    end
  end
end

private def with_term(value : String?, &)
  saved = ENV["TERM"]?
  if value
    ENV["TERM"] = value
  else
    ENV.delete("TERM")
  end
  begin
    yield
  ensure
    if saved
      ENV["TERM"] = saved
    else
      ENV.delete("TERM")
    end
  end
end
