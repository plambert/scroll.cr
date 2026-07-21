require "./spec_helper"

module Scroll
  describe CLI do
    it "defaults to 10 lines" do
      CLI.new([] of String).lines.should eq(10)
    end

    it "treats a bare -N as shorthand for --lines N" do
      CLI.new(["-20"]).lines.should eq(20)
    end

    it "accepts -n INT" do
      CLI.new(["-n", "5"]).lines.should eq(5)
    end

    it "accepts --lines INT" do
      CLI.new(["--lines", "7"]).lines.should eq(7)
    end

    it "does not confuse -n with the bare-number shorthand" do
      CLI.new(["-n", "3"]).lines.should eq(3)
    end

    it "parses the display flags" do
      cli = CLI.new(["--force", "--no-sanitize", "--final", "--interval", "100"])
      cli.force?.should be_true
      cli.sanitize?.should be_false
      cli.final?.should be_true
      cli.interval_ms.should eq(100)
    end

    it "defaults to sanitizing and drawing only on a tty" do
      cli = CLI.new([] of String)
      cli.sanitize?.should be_true
      cli.force?.should be_false
      cli.final?.should be_false
    end

    it "defaults --null to unspecified" do
      CLI.new([] of String).null.should be_nil
    end

    it "sets --null true" do
      CLI.new(["--null"]).null.should be_true
    end

    it "sets --no-null false" do
      CLI.new(["--no-null"]).null.should be_false
    end

    it "lets the last of --null/--no-null win" do
      CLI.new(["--null", "--no-null"]).null.should be_false
      CLI.new(["--no-null", "--null"]).null.should be_true
    end

    it "composes --null with other flags" do
      cli = CLI.new(["--null", "-20"])
      cli.lines.should eq(20)
      cli.null.should be_true
    end

    it "raises on an unknown option" do
      expect_raises(ArgumentError, /unknown option/) { CLI.new(["--nope"]) }
    end

    it "raises on a non-integer line count" do
      expect_raises(ArgumentError, /not an integer/) { CLI.new(["-n", "abc"]) }
    end

    it "raises when the line count is below 1" do
      expect_raises(ArgumentError, /must be >= 1/) { CLI.new(["-0"]) }
    end

    it "raises on an unexpected positional argument" do
      expect_raises(ArgumentError, /unexpected argument/) { CLI.new(["file.txt"]) }
    end
  end
end
