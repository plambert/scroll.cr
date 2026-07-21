require "./spec_helper"

# Parse without running, the way `dispatch` would, and apply the cross-flag rules.
private def parse(args : Array(String)) : Scroll::CLI
  cli = Scroll::CLI.parse(Scroll::CLI.expand_count_shorthand(args))
  cli.validate!
  cli
end

module Scroll
  describe CLI do
    describe "defaults" do
      it "uses the documented defaults" do
        cli = parse([] of String)
        cli.lines.should eq(10)
        cli.interval_ms.should eq(40)
        cli.force?.should be_false
        cli.sanitize?.should be_true
        cli.final?.should be_false
        cli.null.should be_nil
        cli.file?.should be_false
        cli.sort?.should be_false
        cli.reverse?.should be_false
        cli.human?.should be_false
        cli.sort_by.should be_nil
        cli.alt?.should be_false
        cli.alt_mode.should eq(CLI::AltMode::Auto)
      end
    end

    describe "line count" do
      it "accepts -n, --lines, and the bare -N shorthand" do
        parse(["-n", "5"]).lines.should eq(5)
        parse(["--lines", "7"]).lines.should eq(7)
        parse(["-20"]).lines.should eq(20)
      end

      it "does not confuse -n with the bare-number shorthand" do
        parse(["-n", "3"]).lines.should eq(3)
      end

      it "rejects a line count below 1" do
        expect_raises(Shell::AutoComplete::ParseError, /range/) { parse(["-n", "0"]) }
      end
    end

    describe "display flags" do
      it "parses --force, --final, and --interval" do
        cli = parse(["--force", "--final", "--interval", "100"])
        cli.force?.should be_true
        cli.final?.should be_true
        cli.interval_ms.should eq(100)
      end

      it "negates --sanitize with --no-sanitize" do
        parse(["--no-sanitize"]).sanitize?.should be_false
        parse(["--sanitize"]).sanitize?.should be_true
      end
    end

    describe "--null" do
      it "is a tri-state resolved later by Runner" do
        parse([] of String).null.should be_nil
        parse(["--null"]).null.should be_true
        parse(["--no-null"]).null.should be_false
      end

      it "lets the last of --null/--no-null win" do
        parse(["--null", "--no-null"]).null.should be_false
        parse(["--no-null", "--null"]).null.should be_true
      end
    end

    describe "--file" do
      it "accepts -f/--file and reports file mode" do
        parse(["-f", "log.txt"]).file.should eq(Path["log.txt"])
        cli = parse(["--file", "log.txt"])
        cli.file.should eq(Path["log.txt"])
        cli.file?.should be_true
      end

      it "leaves --null unspecified in file mode (silent STDOUT is resolved later)" do
        cli = parse(["-f", "log.txt"])
        cli.null.should be_nil
        cli.file?.should be_true
      end

      it "keeps --no-null explicit in file mode so teeing wins" do
        parse(["-f", "log.txt", "--no-null"]).null.should be_false
      end

      it "parses the follow knobs" do
        cli = parse(["-f", "log.txt", "--from-start", "--poll", "50", "--pid", "42"])
        cli.from_start?.should be_true
        cli.poll_ms.should eq(50)
        cli.pid.should eq(42)
      end

      it "rejects a non-positive --pid or --poll" do
        expect_raises(Shell::AutoComplete::ParseError, /range/) { parse(["-f", "log.txt", "--pid", "0"]) }
        expect_raises(Shell::AutoComplete::ParseError, /range/) { parse(["-f", "log.txt", "--poll", "0"]) }
      end

      it "rejects follow knobs without --file" do
        expect_raises(Shell::AutoComplete::ParseError, /--from-start requires --file/) { parse(["--from-start"]) }
        expect_raises(Shell::AutoComplete::ParseError, /--pid requires --file/) { parse(["--pid", "42"]) }
        expect_raises(Shell::AutoComplete::ParseError, /--poll requires --file/) { parse(["--poll", "50"]) }
      end

      {% unless flag?(:linux) %}
        it "rejects --watch-proc off Linux" do
          expect_raises(Shell::AutoComplete::ParseError, /only supported on Linux/) do
            parse(["-f", "log.txt", "--watch-proc"])
          end
        end
      {% end %}
    end

    describe "sorting" do
      it "parses -s/--sort and -r/--reverse" do
        parse(["-s"]).sort?.should be_true
        parse(["--sort"]).sort?.should be_true
        parse(["-r"]).reverse?.should be_true
        parse(["--reverse"]).reverse?.should be_true
      end

      it "does not confuse -r/-s with the bare-number shorthand" do
        cli = parse(["-r", "-s", "-5"])
        cli.reverse?.should be_true
        cli.sort?.should be_true
        cli.lines.should eq(5)
      end

      it "parses --sort-by INT into a Field selector and implies --sort" do
        cli = parse(["--sort-by", "2"])
        cli.sort?.should be_true
        cli.sort_by.should be_a(SortKey::Field)
        cli.sort_by.as(SortKey::Field).index.should eq(2)
      end

      it "parses --sort-by /regex/ into a Pattern selector and implies --sort" do
        cli = parse(["--sort-by", "/(?<sort>\\d+)/"])
        cli.sort?.should be_true
        cli.sort_by.should be_a(SortKey::Pattern)
      end

      it "sets --human and implies --sort" do
        cli = parse(["--human"])
        cli.human?.should be_true
        cli.sort?.should be_true
      end

      # A transform raises ArgumentError; `dispatch` converts it to a ParseError
      # and reports it as `scroll: --sort-by: ...`.
      it "rejects an invalid --sort-by" do
        expect_raises(ArgumentError, /--sort-by: must be >= 1/) { parse(["--sort-by", "0"]) }
        expect_raises(ArgumentError, /--sort-by: not an integer/) { parse(["--sort-by", "abc"]) }
        expect_raises(ArgumentError, /--sort-by: invalid regex/) { parse(["--sort-by", "/(unclosed/"]) }
      end
    end

    describe "alternate screen" do
      it "enables auto mode with --alt" do
        cli = parse(["--alt"])
        cli.alt?.should be_true
        cli.alt_mode.should eq(CLI::AltMode::Auto)
      end

      it "forces region mode with --alt-region" do
        cli = parse(["--alt-region"])
        cli.alt?.should be_true
        cli.alt_mode.should eq(CLI::AltMode::Region)
      end

      it "forces full mode with --alt-full, still accepting -N" do
        cli = parse(["--alt-full", "-n", "20"])
        cli.alt?.should be_true
        cli.alt_mode.should eq(CLI::AltMode::Full)
        cli.lines.should eq(20)
      end

      it "rejects contradictory alt modes" do
        expect_raises(Shell::AutoComplete::ParseError, /mutually exclusive/) do
          parse(["--alt-region", "--alt-full"])
        end
      end
    end

    describe "errors" do
      it "raises on an unknown option" do
        expect_raises(Shell::AutoComplete::ParseError, /unknown flag/) { parse(["--nope"]) }
      end

      it "raises on an unexpected positional argument" do
        expect_raises(Shell::AutoComplete::ParseError, /positional/) { parse(["file.txt"]) }
      end
    end
  end
end
