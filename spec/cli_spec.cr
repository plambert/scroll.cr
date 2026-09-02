require "./spec_helper"

# Parse without running, the way `dispatch` would, and apply the cross-flag rules.
private def parse(args : Array(String)) : Scroll::CLI
  cli = Scroll::CLI.parse(Scroll::CLI.expand_count_shorthand(args))
  cli.validate!
  cli
end

# Answer a completion callback the way `Scroll.run` does — same composition, with
# stdout captured so the candidates can be inspected.
private def complete(args : Array(String)) : Array(String)
  io = IO::Memory.new
  Scroll::CLI.dispatch(Scroll::CLI.expand_count_shorthand(args), stdout: io)
  io.to_s.lines
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
        cli.fullscreen?.should be_false
        cli.leave?.should be_false
        cli.progress_charset.should eq(Progress::Charset::Unicode)
        cli.color.should eq(CLI::ColorMode::Auto)
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

      # The transform raises ArgumentError; the parser turns it into a ParseError
      # carrying the flag name, so it reads as `scroll: --sort-by: ...`.
      it "rejects an invalid --sort-by" do
        expect_raises(Shell::AutoComplete::ParseError, /--sort-by: must be >= 1/) { parse(["--sort-by", "0"]) }
        expect_raises(Shell::AutoComplete::ParseError, /--sort-by: not an integer/) { parse(["--sort-by", "abc"]) }
        expect_raises(Shell::AutoComplete::ParseError, /--sort-by: invalid regex/) { parse(["--sort-by", "/(unclosed/"]) }
      end
    end

    describe "alternate screen" do
      it "draws on the alternate screen with --fullscreen" do
        parse(["--fullscreen"]).fullscreen?.should be_true
      end

      it "takes the negation back to the inline display" do
        parse(["--fullscreen", "--no-fullscreen"]).fullscreen?.should be_false
      end

      it "leaves the visible lines behind with --leave" do
        cli = parse(["--fullscreen", "--leave"])
        cli.leave?.should be_true
      end

      # --leave only means anything to a display that is torn down on exit.
      it "rejects --leave without --fullscreen" do
        expect_raises(Shell::AutoComplete::ParseError, /--leave requires --fullscreen/) do
          parse(["--leave"])
        end
      end
    end

    describe "color" do
      it "reads --color as a mode" do
        parse(["--color", "on"]).color.should eq(CLI::ColorMode::On)
        parse(["--color", "off"]).color.should eq(CLI::ColorMode::Off)
        parse(["--color", "auto"]).color.should eq(CLI::ColorMode::Auto)
      end

      it "takes -c and -C as shorthand for on and off" do
        parse(["-c"]).color.should eq(CLI::ColorMode::On)
        parse(["-C"]).color.should eq(CLI::ColorMode::Off)
      end

      it "resolves the shorthand last-wins, as one value stream" do
        parse(["-c", "-C"]).color.should eq(CLI::ColorMode::Off)
        parse(["-C", "--color", "on"]).color.should eq(CLI::ColorMode::On)
      end

      it "obeys an explicit mode whatever the terminal is" do
        CLI.color_enabled?(CLI::ColorMode::On, false, "1", nil).should be_true
        CLI.color_enabled?(CLI::ColorMode::Off, true, nil, "xterm").should be_false
      end

      # Auto follows the display, and stands down for NO_COLOR or a terminal
      # that cannot show it.
      it "colors automatically only on a capable terminal" do
        CLI.color_enabled?(CLI::ColorMode::Auto, true, nil, "xterm-256color").should be_true
        CLI.color_enabled?(CLI::ColorMode::Auto, false, nil, "xterm").should be_false
        CLI.color_enabled?(CLI::ColorMode::Auto, true, "1", "xterm").should be_false
        CLI.color_enabled?(CLI::ColorMode::Auto, true, nil, "dumb").should be_false
        CLI.color_enabled?(CLI::ColorMode::Auto, true, nil, "").should be_false
        CLI.color_enabled?(CLI::ColorMode::Auto, true, nil, nil).should be_false
      end
    end

    describe "progress charset" do
      it "reads --progress-charset" do
        parse(["--progress-charset", "ascii"]).progress_charset.should eq(Progress::Charset::Ascii)
        parse(["--progress-charset", "unicode"]).progress_charset.should eq(Progress::Charset::Unicode)
      end
    end

    describe "progress" do
      it "is off unless asked for" do
        cli = parse([] of String)
        cli.progress?.should be_false
        cli.size.should be_nil
        cli.size_lines.should be_nil
        cli.size_file.should be_nil
        cli.name_text.should be_nil
      end

      it "turns on with --progress" do
        parse(["--progress"]).progress?.should be_true
      end

      it "reads --size as a 1024-based byte count" do
        parse(["--size", "1.5k"]).size.should eq(1536)
        parse(["--size", "2M"]).size.should eq(2 * 1024 * 1024)
      end

      it "rejects a --size that is not a byte count" do
        expect_raises(Shell::AutoComplete::ParseError, /not a byte size/) do
          parse(["--size", "huge"])
        end
      end

      it "reads --size-lines as a line count" do
        parse(["--size-lines", "100"]).size_lines.should eq(100)
      end

      it "rejects a --size-lines below one" do
        expect_raises(Shell::AutoComplete::ParseError) { parse(["--size-lines", "0"]) }
      end

      it "takes --file-size from an existing file" do
        file = File.tempfile("scroll-size")
        begin
          parse(["--file-size", file.path]).size_file.should eq(Path[file.path])
        ensure
          file.delete
        end
      end

      it "rejects a --file-size that is not a file" do
        expect_raises(Shell::AutoComplete::ParseError, /not a file/) do
          parse(["--file-size", "/no/such/file/here"])
        end
      end

      it "keeps --name as given" do
        parse(["--name", "build.log"]).name_text.should eq("build.log")
      end

      # Naming a size or a label is only useful to the progress line, so each
      # implies it, the way --sort-by implies --sort.
      it "turns the progress line on from any of the size options and --name" do
        parse(["--size", "1k"]).progress?.should be_true
        parse(["--size-lines", "10"]).progress?.should be_true
        parse(["--name", "build.log"]).progress?.should be_true
      end
    end

    # The generated bash/zsh/fish wrappers call `scroll __complete <cword>
    # <words...>`. expand_count_shorthand must leave those words alone: rewriting
    # one token into two would shift every later word without moving cword, so the
    # shell would be offered candidates for the wrong word.
    describe "completion" do
      it "completes the cursor word when a bare -N is already on the line" do
        candidates = complete(["__complete", "2", "scroll", "-20", "--fi"])
        candidates.should contain("--file")
        candidates.should contain("--file-size")
        candidates.should contain("--final")
      end

      it "offers the same candidates with and without a bare -N on the line" do
        with_shorthand = complete(["__complete", "2", "scroll", "-20", "--fi"])
        without = complete(["__complete", "1", "scroll", "--fi"])
        with_shorthand.should eq(without)
      end

      # -c and -C expand the same way, and must be left alone here too.
      it "offers the same candidates with a color shorthand on the line" do
        with_shorthand = complete(["__complete", "2", "scroll", "-C", "--fi"])
        without = complete(["__complete", "1", "scroll", "--fi"])
        with_shorthand.should eq(without)
      end

      it "completes an enum flag's values" do
        complete(["__complete", "2", "scroll", "--color", ""])
          .should eq(["auto", "on", "off"])
        complete(["__complete", "2", "scroll", "--progress-charset", ""])
          .should eq(["unicode", "ascii"])
      end

      it "offers filesystem completion for --name" do
        complete(["__complete", "2", "scroll", "--name", ""]).should eq(["__sac_complete_files__"])
      end

      it "still expands the shorthands outside a completion callback" do
        CLI.expand_count_shorthand(["-20"]).should eq(["--lines", "20"])
        CLI.expand_count_shorthand(["-c"]).should eq(["--color", "on"])
        CLI.expand_count_shorthand(["-C"]).should eq(["--color", "off"])
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
