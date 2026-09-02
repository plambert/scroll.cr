require "./spec_helper"

# The top-priority guarantee: whatever happens on the STDERR display, the STDOUT
# copy must be a byte-for-byte reproduction of STDIN. This drives the built
# binary end to end with STDERR pointed at /dev/null (no tty, no display).
describe "scroll passthrough" do
  binary = File.expand_path("../bin/scroll", __DIR__)

  it "reproduces text input on STDOUT byte-for-byte" do
    pending! "run `shards build` first" unless File.exists?(binary)
    input = String.build { |str| 1.upto(5000) { |line| str << line << '\n' } }
    output = run_binary(binary, input.to_slice)
    output.should eq(input.to_slice)
  end

  it "reproduces input with no trailing newline" do
    pending! "run `shards build` first" unless File.exists?(binary)
    input = "one\ntwo\nthree".to_slice
    run_binary(binary, input).should eq(input)
  end

  it "writes nothing to STDOUT with --null" do
    pending! "run `shards build` first" unless File.exists?(binary)
    input = String.build { |str| 1.upto(5000) { |line| str << line << '\n' } }
    run_binary(binary, input.to_slice, args: ["--null"]).should eq(Bytes.empty)
  end

  it "reproduces input on STDOUT with --no-null" do
    pending! "run `shards build` first" unless File.exists?(binary)
    input = String.build { |str| 1.upto(5000) { |line| str << line << '\n' } }
    run_binary(binary, input.to_slice, args: ["--no-null"]).should eq(input.to_slice)
  end

  # These change only the STDERR display strategy; STDOUT must stay byte-for-byte
  # either way (and here STDERR is closed, so the display is off).
  {% for flag in ["--fullscreen", "--progress"] %}
    it "reproduces STDOUT byte-for-byte with {{ flag.id }}" do
      pending! "run `shards build` first" unless File.exists?(binary)
      input = String.build { |str| 1.upto(5000) { |line| str << line << '\n' } }
      run_binary(binary, input.to_slice, [{{ flag }}]).should eq(input.to_slice)
    end
  {% end %}
end

private def run_binary(binary : String, input : Bytes, args : Array(String) = [] of String) : Bytes
  output = IO::Memory.new
  process = Process.new(binary, args, input: :pipe, output: :pipe, error: :close)
  spawn do
    process.input.write input
    process.input.close
  end
  IO.copy(process.output, output)
  process.wait
  Fiber.yield
  output.to_slice
end
