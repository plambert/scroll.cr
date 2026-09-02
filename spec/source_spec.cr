require "./spec_helper"

module Scroll
  # A small poll keeps the follow tests fast without busy-spinning.
  POLL = 5.milliseconds

  # Read from `source` in a spawned fiber until `expected` bytes have arrived,
  # then return them. Fails instead of hanging if they never do.
  private def self.follow(source : FileSource, expected : Int32, timeout = 3.seconds) : Bytes
    result = Channel(Bytes).new
    spawn do
      collected = IO::Memory.new
      buffer = Bytes.new(4096)
      while collected.bytesize < expected
        count = source.read(buffer)
        break if count == 0
        collected.write buffer[0, count]
      end
      result.send collected.to_slice
    end
    select
    when bytes = result.receive
      bytes
    when timeout(timeout)
      raise "timed out waiting for #{expected} bytes"
    end
  end

  # Read until terminal EOF (read returns 0), returning everything drained.
  private def self.drain(source : FileSource, timeout = 3.seconds) : Bytes
    result = Channel(Bytes).new
    spawn do
      collected = IO::Memory.new
      buffer = Bytes.new(4096)
      loop do
        count = source.read(buffer)
        break if count == 0
        collected.write buffer[0, count]
      end
      result.send collected.to_slice
    end
    select
    when bytes = result.receive
      bytes
    when timeout(timeout)
      raise "timed out waiting for EOF"
    end
  end

  private def self.with_temp_path(&)
    path = File.tempname("scroll-source")
    begin
      yield path
    ensure
      File.delete?(path)
    end
  end

  describe FileSource do
    it "follows data appended after opening at the end" do
      with_temp_path do |path|
        File.write(path, "") # exists but empty, so open-at-end starts at 0
        source = FileSource.new(path, POLL)
        spawn do
          sleep 30.milliseconds
          File.open(path, "a", &.print("a\nb\n"))
        end
        String.new(follow(source, 4)).should eq("a\nb\n")
        source.close
      end
    end

    # A follow that opened at the very end left the display empty until the file
    # was written to, which reads as a hang; priming shows the lines already
    # there, the way `tail -F` does.
    it "opens on the last prime_lines lines of an existing file" do
      with_temp_path do |path|
        File.write(path, "1\n2\n3\n4\n5\n")
        source = FileSource.new(path, POLL, prime_lines: 2)
        String.new(follow(source, 4)).should eq("4\n5\n")
        source.close
      end
    end

    it "opens on the whole file when it holds fewer lines than that" do
      with_temp_path do |path|
        File.write(path, "1\n2\n")
        source = FileSource.new(path, POLL, prime_lines: 10)
        String.new(follow(source, 4)).should eq("1\n2\n")
        source.close
      end
    end

    it "primes without a trailing newline, and keeps following after" do
      with_temp_path do |path|
        File.write(path, "1\n2\n3")
        source = FileSource.new(path, POLL, prime_lines: 2)
        spawn do
          sleep 30.milliseconds
          File.open(path, "a", &.print("\n4\n"))
        end
        String.new(follow(source, 6)).should eq("2\n3\n4\n")
        source.close
      end
    end

    it "opens at the end when no lines are asked for" do
      with_temp_path do |path|
        File.write(path, "1\n2\n3\n")
        source = FileSource.new(path, POLL)
        spawn do
          sleep 30.milliseconds
          File.open(path, "a", &.print("4\n"))
        end
        String.new(follow(source, 2)).should eq("4\n")
        source.close
      end
    end

    describe ".tail_offset" do
      it "finds the start of the last N lines" do
        with_temp_path do |path|
          File.write(path, "aaa\nbb\nc\n")
          File.open(path) do |file|
            FileSource.tail_offset(file, 1).should eq(7) # "c\n"
            FileSource.tail_offset(file, 2).should eq(4) # "bb\nc\n"
            FileSource.tail_offset(file, 3).should eq(0)
            FileSource.tail_offset(file, 9).should eq(0)
          end
        end
      end

      it "counts the last line when the file does not end in a newline" do
        with_temp_path do |path|
          File.write(path, "aaa\nbb\nc")
          File.open(path) { |file| FileSource.tail_offset(file, 1).should eq(7) }
        end
      end

      it "scans back across more than one block" do
        with_temp_path do |path|
          File.write(path, (1..5000).map { |number| "line #{number}" }.join("\n") + "\n")
          File.open(path) do |file|
            offset = FileSource.tail_offset(file, 2)
            file.pos = offset
            file.gets_to_end.should eq("line 4999\nline 5000\n")
          end
        end
      end

      it "stays at the end when asked for no lines, and at 0 for an empty file" do
        with_temp_path do |path|
          File.write(path, "a\nb\n")
          File.open(path) { |file| FileSource.tail_offset(file, 0).should eq(4) }
          File.write(path, "")
          File.open(path) { |file| FileSource.tail_offset(file, 5).should eq(0) }
        end
      end
    end

    it "streams existing content first with from_start" do
      with_temp_path do |path|
        File.write(path, "existing\n")
        source = FileSource.new(path, POLL, from_start: true)
        String.new(follow(source, 9)).should eq("existing\n")
        source.close
      end
    end

    it "resumes from zero after truncation" do
      with_temp_path do |path|
        File.write(path, "aaaa\n")
        source = FileSource.new(path, POLL, from_start: true)
        spawn do
          sleep 40.milliseconds
          File.open(path, "w") { } # truncate in place
          sleep 20.milliseconds
          File.open(path, "a", &.print("bb\n"))
        end
        String.new(follow(source, 8)).should eq("aaaa\nbb\n")
        source.close
      end
    end

    it "reopens the new inode after rotation" do
      with_temp_path do |path|
        File.write(path, "old\n")
        source = FileSource.new(path, POLL, from_start: true)
        spawn do
          sleep 40.milliseconds
          File.rename(path, "#{path}.1")
          File.write(path, "new\n")
        end
        String.new(follow(source, 8)).should eq("old\nnew\n")
        source.close
        File.delete?("#{path}.1")
      end
    end

    it "waits for a file that appears after start" do
      with_temp_path do |path|
        File.delete?(path) # ensure it does not exist yet
        source = FileSource.new(path, POLL)
        spawn do
          sleep 40.milliseconds
          File.write(path, "hello\n")
        end
        String.new(follow(source, 6)).should eq("hello\n")
        source.close
      end
    end

    it "drains to EOF then stops once --pid is gone" do
      with_temp_path do |path|
        File.write(path, "bye\n")
        process = Process.new("sleep", ["30"])
        source = FileSource.new(path, POLL, from_start: true, pid: process.pid.to_i32)
        spawn do
          sleep 40.milliseconds
          process.terminate
          process.wait
        end
        String.new(drain(source)).should eq("bye\n")
        source.close
      end
    end

    it "drains then stops when --pid is already dead" do
      with_temp_path do |path|
        File.write(path, "done\n")
        process = Process.new("true")
        process.wait # reap, so the pid is gone before we follow
        source = FileSource.new(path, POLL, from_start: true, pid: process.pid.to_i32)
        String.new(drain(source)).should eq("done\n")
        source.close
      end
    end

    {% if flag?(:linux) %}
      it "exits after the writer-idle timeout with no writer" do
        with_temp_path do |path|
          File.write(path, "x\n")
          source = FileSource.new(path, POLL, from_start: true,
            watch_proc: true, watch_proc_timeout: 100.milliseconds)
          # No process holds the file open, so after draining "x\n" the idle
          # timer expires and read returns 0.
          String.new(drain(source)).should eq("x\n")
          source.close
        end
      end

      it "keeps following while a writer holds the file open" do
        with_temp_path do |path|
          File.write(path, "start\n")
          holder = File.open(path, "a")
          begin
            source = FileSource.new(path, POLL, from_start: true,
              watch_proc: true, watch_proc_timeout: 100.milliseconds)
            spawn do
              sleep 250.milliseconds # longer than the idle timeout
              holder.print "more\n"
              holder.flush
            end
            String.new(follow(source, 11)).should eq("start\nmore\n")
            source.close
          ensure
            holder.close
          end
        end
      end
    {% end %}
  end
end
