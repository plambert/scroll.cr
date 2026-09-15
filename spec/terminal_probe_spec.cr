require "./spec_helper"

# The terminal probe can only be exercised against a terminal, so these drive
# the built binary under a pty that answers XTVERSION however the case wants.
# They are the reason a terminal that answers nothing no longer hangs the run.
private record ProbeRun, elapsed : Float64, osc : Int32, done : Bool

private def probe(answer : String, args : String) : ProbeRun
  binary = File.expand_path("../bin/scroll", __DIR__)
  helper = File.expand_path("support/pty_probe.py", __DIR__)
  output = IO::Memory.new
  status = Process.run("python3",
    [helper, answer, "bash", "-c", "seq 1 2000 | #{binary} #{args} > /dev/null; echo __done__"],
    output: output, error: :inherit)
  raise "pty_probe failed" unless status.success?
  fields = output.to_s.split.to_h { |pair| {pair.split('=')[0], pair.split('=')[1]} }
  ProbeRun.new(
    elapsed: fields["elapsed"].to_f,
    osc: fields["osc"].to_i,
    done: fields["done"] == "True",
  )
end

GHOSTTY = "\\x1bP>|ghostty 1.2.0\\x1b\\\\"
XTERM   = "\\x1bP>|XTerm(390)\\x1b\\\\"

describe "terminal progress probe" do
  binary = File.expand_path("../bin/scroll", __DIR__)

  it "drives the indicator when the terminal names itself as one that shows it" do
    pending! "run `shards build` first" unless File.exists?(binary)
    run = probe(GHOSTTY, "--progress --size-lines 2000 -3")
    run.done.should be_true
    run.osc.should be > 0
  end

  it "stays quiet when the terminal is not one of them" do
    pending! "run `shards build` first" unless File.exists?(binary)
    run = probe(XTERM, "--progress --size-lines 2000 -3")
    run.done.should be_true
    run.osc.should eq(0)
  end

  # The bug this guards: a blocking read on /dev/tty never returned, so the run
  # produced nothing at all on a terminal that ignores the query.
  it "gives up quickly when the terminal answers nothing" do
    pending! "run `shards build` first" unless File.exists?(binary)
    run = probe("-", "--progress --size-lines 2000 -3")
    run.done.should be_true
    run.osc.should eq(0)
    run.elapsed.should be < 2.0
  end

  it "skips the query entirely when told to" do
    pending! "run `shards build` first" unless File.exists?(binary)
    run = probe("-", "--progress --size-lines 2000 --terminal-progress -3")
    run.done.should be_true
    run.osc.should be > 0
  end
end
