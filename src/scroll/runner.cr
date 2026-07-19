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
      @display = @config.force? || STDERR.tty?
    end

    def run : Nil
      STDOUT.sync = true
      if @display
        run_with_display
      else
        run_passthrough
      end
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

    private def render_loop(free : Channel(Bytes), filled : Channel(Chunk?), done : Channel(Nil)) : Nil
      renderer = Renderer.new(STDERR, sanitize: @config.sanitize?)
      tail = Tail.new(@config.lines)
      interval = @config.interval_ms.milliseconds
      last_render = Time.instant
      dirty = false
      renderer.start

      loop do
        select
        when chunk = filled.receive
          break if chunk.nil?
          tail.feed(chunk.buffer[0, chunk.size], chunk.offset)
          free.send chunk.buffer
          dirty = true
          if last_render.elapsed >= interval
            renderer.draw tail.snapshot
            dirty = false
            last_render = Time.instant
          end
        when timeout(interval)
          if dirty
            renderer.draw tail.snapshot
            dirty = false
            last_render = Time.instant
          end
        end
      end

      tail.finalize if @config.final?
      renderer.draw tail.snapshot
      renderer.finish
      done.send nil
    rescue IO::Error
      # STDERR failed (terminal closed). Stop rendering, but keep draining so the
      # hot path never blocks on a full handoff channel, then release the pump.
      drain filled, free
      done.send nil
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
