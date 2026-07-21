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

    # The live inline renderer, once render_loop has created it, so the signal /
    # at_exit teardown can move the cursor below the region and show it.
    @renderer : Renderer? = nil

    def initialize(@config : CLI)
      @suppress = Runner.suppress_stdout?(@config.null, @config.file?)
      @display = Runner.display_enabled?(@config.force?, @suppress, STDERR.tty?, STDOUT.tty?)
      @source = Runner.build_source(@config)
      # --sort must see every line to keep a correct top-N, so the pump blocks for
      # a pool buffer instead of dropping when it falls behind. STDOUT throughput
      # is deliberately relaxed under --sort (it cannot skip lines anyway).
      @may_drop = !@config.sort?
    end

    # STDIN by default; a followed file when --file is set.
    def self.build_source(config : CLI) : Source
      if path = config.file
        FileSource.new(
          path.to_s,
          config.poll_ms.milliseconds,
          from_start: config.from_start?,
          pid: config.pid,
          watch_proc: config.watch_proc?,
          watch_proc_timeout: config.watch_proc_timeout_s.seconds,
        )
      else
        StdinSource.new
      end
    end

    # Should STDOUT be suppressed? User intent (nil/true/false) resolved against
    # whether the active mode implies null. --no-null (false) always wins.
    def self.suppress_stdout?(null_pref : Bool?, mode_implies_null : Bool) : Bool
      case null_pref
      in true  then true              # --null
      in false then false             # --no-null forces teeing
      in Nil   then mode_implies_null # default: implied by mode (e.g. --file)
      end
    end

    # Whether the STDERR tail display runs. When STDOUT is suppressed there is no
    # passthrough to collide with, so the same-terminal suppression is lifted.
    def self.display_enabled?(force : Bool, suppress_stdout : Bool, stderr_tty : Bool, stdout_tty : Bool) : Bool
      return true if force
      return stderr_tty if suppress_stdout
      return false if stderr_tty && stdout_tty
      stderr_tty
    end

    def run : Nil
      STDOUT.sync = true
      if @display
        run_with_display
      else
        warn_stdout_is_tty if STDERR.tty? && STDOUT.tty? && !@config.force? && !@suppress
        run_passthrough
      end
    ensure
      @source.close
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
        count = @source.read(buffer)
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
        pooled = acquire_buffer free
        buffer = pooled || reserved
        count = @source.read(buffer)
        break if count == 0
        write_stdout buffer[0, count]
        filled.send(Chunk.new(buffer, count, offset)) unless pooled.nil?
        offset += count
      end
    end

    # Get a pool buffer without blocking STDOUT. If the pool is momentarily
    # empty, yield once so the cooperatively-scheduled render fiber can recycle
    # buffers, then retry. Under a steady trickle of small reads the pump would
    # otherwise never yield, starve the render fiber, drain the pool, and drop
    # chunks (each drop forces a contiguity reset in the display). If the render
    # fiber is genuinely behind (parked on a slow STDERR write) the yield returns
    # at once and we fall back to a drop, so STDOUT is never gated on STDERR.
    private def acquire_buffer(free : Channel(Bytes)) : Bytes?
      if buffer = try_receive free
        return buffer
      end
      return free.receive unless @may_drop # --sort: wait for a buffer, never drop
      Fiber.yield
      try_receive free
    end

    # The render fiber never creates a timer event of its own: it only ever
    # blocks on a channel receive or on a STDERR write. The periodic redraw is
    # driven by a separate ticker fiber whose only job is to sleep and post a
    # tick. Keeping the timer machinery on a fiber that does no blocking IO
    # avoids the io_write-vs-select_timeout conflict path in the event loop.
    private def render_loop(free : Channel(Bytes), filled : Channel(Chunk?), done : Channel(Nil)) : Nil
      return alt_render_loop(free, filled, done) if @config.alt?
      return sort_render_loop(free, filled, done) if @config.sort?

      # Assigned before the begin so it is guaranteed non-nil in the rescue.
      ticking = Atomic(Bool).new(true)
      begin
        renderer = Renderer.new(STDERR, @config.lines, sanitize: @config.sanitize?)
        @renderer = renderer
        tail = Tail.new(@config.lines)
        sorter = Sorter.new(@config.sort?, @config.reverse?, @config.human?, @config.sort_by)
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
              renderer.draw sorter.order(tail.snapshot)
              dirty = false
            end
          end
        end

        ticking.set false
        tail.finalize(@config.final?)
        renderer.draw sorter.order(tail.snapshot)
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

    # The --sort render loop. Same channel/ticker structure as render_loop, but a
    # SortWindow keeps the top-N of the whole stream (not the last N received) and
    # is already in display order, so it is drawn directly. The pump does not drop
    # in this mode (see acquire_buffer), so the window sees every line.
    private def sort_render_loop(free : Channel(Bytes), filled : Channel(Chunk?), done : Channel(Nil)) : Nil
      ticking = Atomic(Bool).new(true)
      begin
        renderer = Renderer.new(STDERR, @config.lines, sanitize: @config.sanitize?)
        @renderer = renderer
        sorter = Sorter.new(@config.sort?, @config.reverse?, @config.human?, @config.sort_by)
        window = SortWindow.new(@config.lines, sorter)
        ticks = Channel(Nil).new(1)
        start_ticker(ticks, ticking)
        dirty = false
        renderer.start

        loop do
          select
          when message = filled.receive
            break if message.nil?
            window.feed(message.buffer[0, message.size])
            free.send message.buffer
            dirty = true
          when ticks.receive
            if dirty
              renderer.draw window.snapshot
              dirty = false
            end
          end
        end

        ticking.set false
        window.finalize(@config.final?)
        renderer.draw window.snapshot
        renderer.finish
        done.send nil
      rescue IO::Error
        ticking.set false
        drain filled, free
        done.send nil
      end
    end

    # The --alt render loop. Same channel/ticker structure as render_loop, but
    # the display is an AltRenderer that appends complete lines to the alternate
    # screen instead of repainting a fixed window. Region mode also installs a
    # SIGWINCH trap so the scroll band is re-applied on resize.
    private def alt_render_loop(free : Channel(Bytes), filled : Channel(Chunk?), done : Channel(Nil)) : Nil
      ticking = Atomic(Bool).new(true)
      begin
        renderer = AltRenderer.new(STDERR, @config.lines, sanitize: @config.sanitize?, region: alt_region?)
        ticks = Channel(Nil).new(1)
        start_ticker(ticks, ticking)
        dirty = false
        Signal::WINCH.trap { renderer.notify_resize }
        renderer.start

        loop do
          select
          when message = filled.receive
            break if message.nil?
            renderer.feed(message.buffer[0, message.size], message.offset)
            free.send message.buffer
            dirty = true
          when ticks.receive
            if dirty
              renderer.flush
              dirty = false
            end
          end
        end

        ticking.set false
        renderer.finish(@config.final?)
        done.send nil
      rescue IO::Error
        # STDERR failed (terminal closed). Stop rendering, but keep draining so
        # the hot path never blocks on a full handoff channel, then release it.
        ticking.set false
        drain filled, free
        done.send nil
      end
    end

    # Resolve the concrete alt mode. Auto assumes region mode unless $TERM marks
    # a non-VT terminal.
    private def alt_region? : Bool
      case @config.alt_mode
      in .region? then true
      in .full?   then false
      in .auto?   then Terminal.scroll_region_supported?
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
      return if @suppress
      STDOUT.write slice
    rescue ex : IO::Error
      raise ex unless ex.os_error == Errno::EPIPE || ex.message.try(&.includes?("Broken pipe"))
      exit 0 # downstream is gone; the passthrough has nothing left to do
    end

    private def install_display_teardown : Nil
      # --alt teardown must also leave the alt screen and reset the scroll region;
      # the inline path only needs the cursor shown. Both restores are idempotent
      # and safe even if the display never started.
      if @config.alt?
        at_exit { AltRenderer.restore(STDERR) }
      else
        # Move the cursor below the region and show it (a proper finish), so
        # Ctrl-C / SIGTERM leave a clean terminal rather than the cursor mid-region.
        at_exit do
          if renderer = @renderer
            renderer.finish
          else
            Renderer.restore(STDERR)
          end
        end
      end
      # Turn a termination signal into a normal exit so the at_exit hook restores
      # the cursor instead of leaving the terminal in a hidden-cursor state.
      Process.on_terminate do |reason|
        exit(reason.interrupted? ? 130 : 143)
      end
    end
  end
end
