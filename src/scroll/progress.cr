module Scroll
  # The progress line drawn under the tail when --progress is on.
  #
  # Two shapes, chosen by whether the input size is known:
  #
  #     unknown:  1.2M 12K ln 840K/s 1.2K ln/s  NAME
  #     known:     45% ███████░░░ 1.2M/2.6M eta 2m01s 840K/s 12K ln  NAME
  #
  # Counting happens on the hot path (see `Counters`), so the numbers are exact
  # even when the display drops chunks; the meter itself only formats.
  class Progress
    FILL  = '█'
    EMPTY = '░'

    # Columns the bar wants before the name starts stealing from it, and the
    # floor it will not go below while a name is present.
    PREFERRED_BAR = 30
    MINIMUM_BAR   = 10

    # Columns a name is worth giving up stats fields for. Below this the name is
    # too clipped to identify anything.
    MINIMUM_NAME = 8

    # Rates are measured over a trailing window rather than the whole run, so a
    # stalled stream shows a falling rate instead of a stale average.
    RATE_WINDOW = 3.seconds

    # A name too long for its field slides left at this rate, holds at the end,
    # then restarts.
    SCROLL_RATE  = 2.0 # columns per second
    SCROLL_PAUSE = 1.second

    BYTE_UNITS  = %w[B K M G T P]
    COUNT_UNITS = ["", "K", "M", "G", "T", "P"]

    NEWLINE = '\n'.ord.to_u8

    # What the run is measured against. Both nil means the size is unknown, which
    # is what drops the bar, the percentage, and the ETA from the line.
    struct Total
      getter bytes : Int64?
      getter lines : Int64?

      def initialize(@bytes : Int64? = nil, @lines : Int64? = nil)
      end

      def known? : Bool
        !(@bytes.nil? && @lines.nil?)
      end
    end

    # Byte and line totals, written by the pump and read by the render fiber.
    # Atomic because those are separate fibers, which the scheduler may place on
    # separate threads.
    class Counters
      def initialize
        @bytes = Atomic(Int64).new(0_i64)
        @lines = Atomic(Int64).new(0_i64)
      end

      def add(bytes : Int32, lines : Int32) : Nil
        @bytes.add bytes.to_i64
        @lines.add lines.to_i64
      end

      def bytes : Int64
        @bytes.get
      end

      def lines : Int64
        @lines.get
      end

      # Newlines in a chunk. On the hot path, so it walks the slice rather than
      # materializing a String.
      def self.newlines(slice : Bytes) : Int32
        count = 0
        slice.each { |byte| count += 1 if byte == NEWLINE }
        count
      end
    end

    private record Sample, at : Time::Instant, bytes : Int64, lines : Int64

    # One field of the line: its text, and the order it is given up in when the
    # terminal is too narrow. Rank 0 is never dropped.
    private record Field, text : String, rank : Int32

    # A byte size: an integer, or a decimal with a 1024-based suffix. Case
    # insensitive, and an "i" and/or "b" may trail the suffix letter (1.5k,
    # 1.5K, 1.5KB, 1.5KiB are the same size).
    SIZE = /\A(\d+(?:\.\d+)?)\s*([kmgtp])?(i?b)?\z/i

    def self.parse_size(value : String) : Int64
      match = SIZE.match(value.strip) || raise ArgumentError.new "not a byte size: #{value}"
      power = case match[2]?.try(&.downcase)
              when nil then 0
              when "k" then 1
              when "m" then 2
              when "g" then 3
              when "t" then 4
              else          5
              end
      scaled = match[1].to_f * (1024.0 ** power)
      raise ArgumentError.new "must be at least 1 byte: #{value}" if scaled < 1
      raise ArgumentError.new "too large: #{value}" if scaled > Int64::MAX.to_f
      scaled.to_i64
    end

    # Fold the three size options into one total. A byte size always wins over a
    # line count, and --size over --file-size; each loser is reported so the
    # caller can warn about the option it ignored.
    def self.resolve(size : Int64?, size_lines : Int64?, file_size : Int64?) : {Total, Array(String)}
      warnings = [] of String
      bytes = size

      if from_file = file_size
        if bytes
          warnings << "--file-size ignored; --size takes precedence"
        else
          bytes = from_file
        end
      end

      if bytes
        warnings << "--size-lines ignored; a byte size takes precedence" if size_lines
        {Total.new(bytes: bytes), warnings}
      else
        {Total.new(lines: size_lines), warnings}
      end
    end

    @name : String?

    def initialize(@total : Total, name : String? = nil, @started_at : Time::Instant = Time.instant)
      @name = name.try { |text| Progress.sanitize(text) }
      @samples = Deque(Sample).new
      @samples.push Sample.new(@started_at, 0_i64, 0_i64)
    end

    # The whole line, at most `width` columns.
    def render(width : Int32, bytes : Int64, lines : Int64, now : Time::Instant = Time.instant) : String
      return "" if width < 1
      sample now, bytes, lines
      byte_rate, line_rate = rates
      done = fraction bytes, lines

      fields = [] of Field
      if done
        fields << Field.new("#{(done * 100).to_i}%".rjust(4), 0)
        fields << Field.new(pair(bytes, lines), 1)
        fields << Field.new("eta #{eta(bytes, lines, byte_rate, line_rate)}", 2)
        fields << Field.new("#{Progress.human_bytes(byte_rate.to_i64)}/s", 4)
        fields << Field.new("#{Progress.human_count(lines)} ln", 5)
        fields << Field.new("#{Progress.human_count(line_rate.to_i64)} ln/s", 6)
      else
        fields << Field.new(Progress.human_bytes(bytes), 0)
        fields << Field.new("#{Progress.human_count(lines)} ln", 3)
        fields << Field.new("#{Progress.human_bytes(byte_rate.to_i64)}/s", 4)
        fields << Field.new("#{Progress.human_count(line_rate.to_i64)} ln/s", 5)
      end

      compose width, fields, bar: !done.nil?, done: done || 0.0, elapsed: now - @started_at
    end

    # Lay the kept fields out around the bar and the name. Stats fields are given
    # up worst-rank first while the bar and the name are below the widths worth
    # having; what survives then splits the space per `#assemble`. When even that
    # is not enough, the name goes, and last of all the fields are truncated.
    private def compose(width : Int32, fields : Array(Field), bar : Bool, done : Float64, elapsed : Time::Span) : String
      name = @name
      loop do
        space = space_for width, fields, bar, name
        worth_having = (bar ? MINIMUM_BAR : 0) + (name ? MINIMUM_NAME : 0)
        worth_having = 1 if worth_having < 1

        next if space < worth_having && drop_worst(fields)

        usable = (bar ? 1 : 0) + (name ? 1 : 0)
        usable = 1 if usable < 1
        return assemble(fields, bar, done, name, space, elapsed) if space >= usable

        if name
          name = nil
          next
        end
        return fields.map(&.text).join(' ')[0, width]
      end
    end

    # Give up the worst-ranked field the line can do without. False when every
    # field left is one it keeps at any width.
    private def drop_worst(fields : Array(Field)) : Bool
      worst = fields.max_by?(&.rank)
      return false unless worst && worst.rank > 0
      index = fields.index(worst)
      return false unless index
      fields.delete_at index
      true
    end

    # Columns left for the bar and the name once the fields and the single-space
    # gaps between everything are accounted for.
    private def space_for(width : Int32, fields : Array(Field), bar : Bool, name : String?) : Int32
      slots = fields.size + (bar ? 1 : 0) + (name ? 1 : 0)
      gaps = slots > 1 ? slots - 1 : 0
      width - fields.sum(&.text.size) - gaps
    end

    # Hand `space` columns to the bar and the name. The name is shown whole while
    # that leaves the bar at least PREFERRED_BAR columns; past that the bar keeps
    # shrinking to MINIMUM_BAR and the name takes what is left, scrolling if it
    # still does not fit.
    private def assemble(fields : Array(Field), bar : Bool, done : Float64, name : String?, space : Int32, elapsed : Time::Span) : String
      bar_width = 0
      name_width = 0

      if bar && name
        bar_width = Math.max(MINIMUM_BAR, space - name.size)
        bar_width = space - 1 if bar_width > space - 1
        bar_width = 1 if bar_width < 1
        name_width = space - bar_width
      elsif bar
        bar_width = space
      elsif name
        name_width = space
      end

      parts = [] of String
      parts << fields.first.text
      parts << Progress.bar(bar_width, done) if bar_width > 0
      fields.skip(1).each { |field| parts << field.text }
      parts << Progress.scroll(name, name_width, elapsed) if name && name_width > 0
      parts.join ' '
    end

    # A bar `width` columns wide, `done` of it filled.
    def self.bar(width : Int32, done : Float64) : String
      return "" if width < 1
      filled = (width * done.clamp(0.0, 1.0)).round.to_i
      (FILL.to_s * filled) + (EMPTY.to_s * (width - filled))
    end

    # The window of `name` visible in a field `width` columns wide. A name that
    # fits is returned whole; a longer one slides left at SCROLL_RATE columns per
    # second, holds SCROLL_PAUSE at the end, then starts over.
    def self.scroll(name : String, width : Int32, elapsed : Time::Span) : String
      return "" if width < 1
      return name if name.size <= width

      last_offset = name.size - width
      pause_steps = (SCROLL_PAUSE.total_seconds * SCROLL_RATE).round.to_i
      cycle = last_offset + 1 + pause_steps
      step = (elapsed.total_seconds * SCROLL_RATE).to_i % cycle
      name[Math.min(step, last_offset), width]
    end

    # Strip the control bytes a name could otherwise smuggle into the display.
    def self.sanitize(text : String) : String
      text.gsub { |char| char.control? || (0x80..0x9F).includes?(char.ord) ? "" : char }
    end

    # 1024-based, at most one decimal: 512B, 1.2K, 12K, 1.2M.
    def self.human_bytes(value : Int64) : String
      human value, BYTE_UNITS
    end

    # The same shape without the unit letter at the bottom: 512, 1.2K, 12K.
    def self.human_count(value : Int64) : String
      human value, COUNT_UNITS
    end

    private def self.human(value : Int64, units : Array(String)) : String
      return "0#{units[0]}" if value <= 0
      scaled = value.to_f
      index = 0
      while scaled >= 1024 && index < units.size - 1
        scaled /= 1024
        index += 1
      end
      digits = scaled < 10 && index > 0 ? "%.1f" % scaled : scaled.round.to_i64.to_s
      "#{digits}#{units[index]}"
    end

    # 45s, 2m01s, 1h02m, 3d04h.
    def self.duration(span : Time::Span) : String
      seconds = span.total_seconds
      return "--" if seconds < 0 || !seconds.finite?
      seconds = seconds.round.to_i64
      case seconds
      when .< 60     then "#{seconds}s"
      when .< 3_600  then "#{seconds // 60}m#{(seconds % 60).to_s.rjust(2, '0')}s"
      when .< 86_400 then "#{seconds // 3_600}h#{(seconds % 3_600 // 60).to_s.rjust(2, '0')}m"
      else                "#{seconds // 86_400}d#{(seconds % 86_400 // 3_600).to_s.rjust(2, '0')}h"
      end
    end

    # How much of the input is done, or nil when the size is unknown.
    private def fraction(bytes : Int64, lines : Int64) : Float64?
      if total = @total.bytes
        return (bytes.to_f / total).clamp(0.0, 1.0) if total > 0
      end
      if total = @total.lines
        return (lines.to_f / total).clamp(0.0, 1.0) if total > 0
      end
      nil
    end

    # Whichever basis the total uses drives the estimate.
    private def eta(bytes : Int64, lines : Int64, byte_rate : Float64, line_rate : Float64) : String
      remaining, rate = if total = @total.bytes
                          {total - bytes, byte_rate}
                        elsif total = @total.lines
                          {total - lines, line_rate}
                        else
                          {0_i64, 0.0}
                        end
      return "0s" if remaining <= 0
      return "--" if rate <= 0
      Progress.duration((remaining / rate).seconds)
    end

    # "1.2M/2.6M" against a byte total, "12K/40K ln" against a line total.
    private def pair(bytes : Int64, lines : Int64) : String
      if total = @total.bytes
        "#{Progress.human_bytes(bytes)}/#{Progress.human_bytes(total)}"
      elsif total = @total.lines
        "#{Progress.human_count(lines)}/#{Progress.human_count(total)} ln"
      else
        Progress.human_bytes(bytes)
      end
    end

    private def sample(now : Time::Instant, bytes : Int64, lines : Int64) : Nil
      @samples.push Sample.new(now, bytes, lines)
      # Keep the oldest sample inside the window, and always at least two so a
      # rate can be computed at all.
      while @samples.size > 2 && (now - @samples[1].at) >= RATE_WINDOW
        @samples.shift
      end
    end

    private def rates : {Float64, Float64}
      first = @samples.first
      last = @samples.last
      span = (last.at - first.at).total_seconds
      return {0.0, 0.0} if span <= 0
      {(last.bytes - first.bytes) / span, (last.lines - first.lines) / span}
    end
  end
end
