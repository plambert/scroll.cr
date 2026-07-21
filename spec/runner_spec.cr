require "./spec_helper"

module Scroll
  describe Runner do
    describe ".suppress_stdout?" do
      it "resolves the null intent against whether the mode implies null" do
        # null_pref | mode_implies_null | expected
        Runner.suppress_stdout?(nil, false).should be_false
        Runner.suppress_stdout?(nil, true).should be_true   # file mode implies null
        Runner.suppress_stdout?(true, false).should be_true # --null
        Runner.suppress_stdout?(true, true).should be_true
        Runner.suppress_stdout?(false, false).should be_false # --no-null
        Runner.suppress_stdout?(false, true).should be_false  # --no-null overrides implied null
      end
    end

    describe ".display_enabled?" do
      it "keeps the same-terminal suppression when STDOUT is not suppressed" do
        # force | suppress | stderr_tty | stdout_tty | expected
        Runner.display_enabled?(false, false, true, true).should be_false
        Runner.display_enabled?(false, false, true, false).should be_true
        Runner.display_enabled?(false, false, false, false).should be_false
      end

      it "lifts the same-terminal suppression when STDOUT is suppressed" do
        Runner.display_enabled?(false, true, true, true).should be_true
        Runner.display_enabled?(false, true, true, false).should be_true
        Runner.display_enabled?(false, true, false, false).should be_false
      end

      it "always draws with --force" do
        Runner.display_enabled?(true, false, false, false).should be_true
        Runner.display_enabled?(true, true, false, false).should be_true
        Runner.display_enabled?(true, false, true, true).should be_true
      end
    end
  end
end
