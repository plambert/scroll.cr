module Scroll
  # Ties the pieces together.
  #
  # The hot path (STDIN -> STDOUT) runs in the main fiber and is never gated on
  # the display. Buffers are drawn from a fixed pool; the hot path hands a filled
  # buffer to the render fiber, tagged with its stream offset, and grabs a fresh
  # one for the next read. When the render fiber falls behind, the pool empties;
  # the hot path then reads into a reserved buffer that is written to STDOUT and
  # discarded (not handed off). STDOUT stays at full speed and the skipped bytes
  # simply never reach the display, which the Tail detects as an offset gap.
  class Runner
    CHUNK_SIZE = 64 * 1024
    POOL_SIZE  = 8

    record Chunk, buffer : Bytes, size : Int32, offset : Int64

    def initialize(@config : CLI)
      @display =
        if @config.force?
          true
        elsif STDERR.tty? && STDOUT.tty?
          # STDOUT and STDERR are the same terminal: the passthrough would flood
          # the terminal and collide with the display. Disable the display.
          false
        else
          STDERR.tty?
        end
    end

    def run : Nil
      STDOUT.sync = true
      if @display
        run_with_display
      else
        warn_stdout_is_tty if STDERR.tty? && STDOUT.tty? && !@config.force?
        run_passthrough
      end
    end

    private def warn_stdout_is_tty : Nil
      STDERR.puts "scroll: stdout is a terminal, so the tail display is disabled " \
                  "(it would corrupt the passthrough). Redirect or pipe stdout, " \
                  "e.g. `... | scroll > file`, or pass --force."
    rescue IO::Error
      # Nothing we can do if even the warning can't be written.
    end

    # STDIN -> STDOUT only. Used when STDERR is not a terminal (no display).
    private def run_passthrough : Nil
      buffer = Bytes.new(CHUNK_SIZE)
      loop do
        count = STDIN.read(buffer)
        break if count == 0
        write_stdout buffer[0, count]
      end
    end

    private def run_with_display : Nil
      free = Channel(Bytes).new(POOL_SIZE)
      filled = Channel(Chunk?).new(POOL_SIZE)
      done = Channel(Nil).new
      POOL_SIZE.times { free.send Bytes.new(CHUNK_SIZE) }

      install_display_teardown
      spawn(name: "scroll-render") { render_loop(free, filled, done) }

      pump(free, filled)
      filled.send nil # EOF sentinel
      done.receive    # wait for the final frame and cursor restore
    end

    private def pump(free : Channel(Bytes), filled : Channel(Chunk?)) : Nil
      reserved = Bytes.new(CHUNK_SIZE)
      offset = 0_i64
      loop do
        pooled = try_receive free
        buffer = pooled || reserved
        count = STDIN.read(buffer)
        break if count == 0
        write_stdout buffer[0, count]
        filled.send(Chunk.new(buffer, count, offset)) unless pooled.nil?
        offset += count
      end
    end

    # The render fiber never creates a timer event of its own: it only ever
    # blocks on a channel receive or on a STDERR write. The periodic redraw is
    # driven by a separate ticker fiber whose only job is to sleep and post a
    # tick. Keeping the timer machinery on a fiber that does no blocking IO
    # avoids the io_write-vs-select_timeout conflict path in the event loop.
    private def render_loop(free : Channel(Bytes), filled : Channel(Chunk?), done : Channel(Nil)) : Nil
      # Assigned before the begin so it is guaranteed non-nil in the rescue.
      ticking = Atomic(Bool).new(true)
      begin
        renderer = Renderer.new(STDERR, sanitize: @config.sanitize?)
        tail = Tail.new(@config.lines)
        ticks = Channel(Nil).new(1)
        start_ticker(ticks, ticking)
        dirty = false
        renderer.start

        loop do
          select
          when message = filled.receive
            break if message.nil?
            tail.feed(message.buffer[0, message.size], message.offset)
            free.send message.buffer
            dirty = true
          when ticks.receive
            if dirty
              renderer.draw tail.snapshot
              dirty = false
            end
          end
        end

        ticking.set false
        tail.finalize if @config.final?
        renderer.draw tail.snapshot
        renderer.finish
        done.send nil
      rescue IO::Error
        # STDERR failed (terminal closed). Stop rendering, but keep draining so
        # the hot path never blocks on a full handoff channel, then release it.
        ticking.set false
        drain filled, free
        done.send nil
      end
    end

    private def start_ticker(ticks : Channel(Nil), running : Atomic(Bool)) : Nil
      interval = @config.interval_ms.milliseconds
      interval = 1.millisecond if interval.zero? # avoid a busy-spin ticker
      spawn(name: "scroll-tick") do
        while running.get
          sleep interval
          # Non-blocking post: if a tick is already pending, drop this one.
          select
          when ticks.send(nil)
          else
          end
        end
      end
    end

    private def drain(filled : Channel(Chunk?), free : Channel(Bytes)) : Nil
      loop do
        chunk = filled.receive
        break if chunk.nil?
        free.send chunk.buffer
      end
    end

    private def try_receive(channel : Channel(Bytes)) : Bytes?
      select
      when value = channel.receive
        value
      else
        nil
      end
    end

    private def write_stdout(slice : Bytes) : Nil
      STDOUT.write slice
    rescue ex : IO::Error
      raise ex unless ex.os_error == Errno::EPIPE || ex.message.try(&.includes?("Broken pipe"))
      exit 0 # downstream is gone; the passthrough has nothing left to do
    end

    private def install_display_teardown : Nil
      at_exit { Renderer.restore(STDERR) }
      # Turn a termination signal into a normal exit so the at_exit hook restores
      # the cursor instead of leaving the terminal in a hidden-cursor state.
      Process.on_terminate do |reason|
        exit(reason.interrupted? ? 130 : 143)
      end
    end
  end
end
