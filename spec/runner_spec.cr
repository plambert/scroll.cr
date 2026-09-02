require "./spec_helper"

# Parse args into a CLI the way `Scroll.run` does, without running anything.
private def config(args : Array(String)) : Scroll::CLI
  Scroll::CLI.parse(args)
end

module Scroll
  describe Runner do
    describe ".progress_total" do
      it "takes the size from the file named by --file-size" do
        file = File.tempfile("scroll-size")
        begin
          file.print "x" * 1234
          file.flush
          total, warnings = Runner.progress_total(config(["--file-size", file.path]))
          total.bytes.should eq(1234)
          warnings.should be_empty
        ensure
          file.delete
        end
      end

      it "warns about the line count it ignored when a byte size is also given" do
        total, warnings = Runner.progress_total(config(["--size", "2k", "--size-lines", "50"]))
        total.bytes.should eq(2048)
        warnings.should eq(["--size-lines ignored; a byte size takes precedence"])
      end

      it "reports an unknown total for a bare --progress" do
        total, warnings = Runner.progress_total(config(["--progress"]))
        total.known?.should be_false
        warnings.should be_empty
      end

      # The path is checked at parse time, so a file that vanishes in between
      # degrades to an unknown size rather than taking the run down.
      it "warns and carries on when the file cannot be measured" do
        path = File.tempname("scroll-size")
        cli = CLI.parse(["--progress"] of String)
        cli.size_file = Path[path]
        total, warnings = Runner.progress_total(cli)
        total.known?.should be_false
        warnings.size.should eq(1)
        warnings.first.should start_with("--file-size:")
      end
    end

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

    describe ".build_source" do
      it "builds a StdinSource without --file" do
        Runner.build_source(CLI.parse([] of String)).should be_a(StdinSource)
      end

      it "builds a FileSource with --file" do
        Runner.build_source(CLI.parse(["-f", "log.txt"])).should be_a(FileSource)
      end
    end

    describe "file mode implied null" do
      it "suppresses STDOUT by default in file mode" do
        cli = CLI.parse(["-f", "log.txt"])
        Runner.suppress_stdout?(cli.null, cli.file?).should be_true
      end

      it "tees STDOUT when --no-null is given in file mode" do
        cli = CLI.parse(["-f", "log.txt", "--no-null"])
        Runner.suppress_stdout?(cli.null, cli.file?).should be_false
      end

      it "does not suppress STDOUT in the default STDIN mode" do
        cli = CLI.parse([] of String)
        Runner.suppress_stdout?(cli.null, cli.file?).should be_false
      end
    end
  end
end
