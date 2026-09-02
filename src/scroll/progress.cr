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
    # Which glyphs the bar is drawn from. Unicode adds eighth-of-a-column steps,
    # so the bar moves seven times per column instead of once.
    enum Charset
      Unicode
      Ascii
    end

    FILL    = '█'
    EMPTY   = '░'
    EIGHTHS = %w[▏ ▎ ▍ ▌ ▋ ▊ ▉] # 1/8 .. 7/8 of a column

    ASCII_FILL  = '#'
    ASCII_EMPTY = '-'

    # SGR bodies. The bar leans on background colors so the filled part and the
    # track meet with no gap between glyphs.
    FILLED_STYLE    = "42"     # green background
    TRACK_STYLE     = "100"    # bright black background
    PARTIAL_STYLE   = "32;100" # green on the track, for the leading cell
    PERCENT_STYLE   = "1"      # bold
    SEPARATOR_STYLE = "2"      # dim
    NAME_STYLE      = "36"     # cyan
    RESET           = "\e[0m"

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

    # A painted run: the columns it occupies, and the SGR body to wrap it in when
    # color is on. `text` may already carry escapes (the bar does), which is why
    # the width is carried rather than measured.
    private record Piece, text : String, width : Int32, style : String? = nil do
      def self.plain(text : String, style : String? = nil) : Piece
        new(text, text.size, style)
      end
    end

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

    def initialize(@total : Total, name : String? = nil, @started_at : Time::Instant = Time.instant,
                   @color : Bool = false, @charset : Charset = Charset::Unicode)
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
        fields << Field.new(counterpart(bytes, lines), 5)
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
        return paint([Piece.plain(fields.map(&.text).join(separator)[0, width])])
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

    # The percentage leads, the bar follows it, and the remaining fields are
    # joined by the separator; a name goes last. Everything is spaced by one
    # column, so this is what the bar and the name have left to share.
    private def space_for(width : Int32, fields : Array(Field), bar : Bool, name : String?) : Int32
      lead, rest = lead_and_rest fields, bar
      segments = 0
      segments += 1 if lead
      segments += 1 if bar
      segments += 1 unless rest.empty?
      segments += 1 if name
      gaps = segments > 1 ? segments - 1 : 0
      width - (lead.try(&.text.size) || 0) - joined_width(rest) - gaps
    end

    # With a bar, the first field (the percentage) sits ahead of it and the rest
    # follow; with no bar every field is in the run after it.
    private def lead_and_rest(fields : Array(Field), bar : Bool) : {Field?, Array(Field)}
      return {nil, fields} unless bar
      {fields.first?, fields.size > 1 ? fields.skip(1) : [] of Field}
    end

    private def joined_width(fields : Array(Field)) : Int32
      return 0 if fields.empty?
      fields.sum(&.text.size) + separator.size * (fields.size - 1)
    end

    # Hand `space` columns to the bar and the name. The name is shown whole while
    # that leaves the bar at least PREFERRED_BAR columns; past that the bar keeps
    # shrinking to MINIMUM_BAR and the name takes what is left, scrolling if it
    # still does not fit.
    private def split_space(bar : Bool, name : String?, space : Int32) : {Int32, Int32}
      if bar && name
        bar_width = Math.max(MINIMUM_BAR, space - name.size)
        bar_width = space - 1 if bar_width > space - 1
        bar_width = 1 if bar_width < 1
        {bar_width, space - bar_width}
      elsif bar
        {space, 0}
      elsif name
        {0, space}
      else
        {0, 0}
      end
    end

    private def assemble(fields : Array(Field), bar : Bool, done : Float64, name : String?, space : Int32, elapsed : Time::Span) : String
      bar_width, name_width = split_space bar, name, space
      lead, rest = lead_and_rest fields, bar

      # One column between the percentage, the bar, the stats run, and the name;
      # inside the run the separator carries its own spacing.
      segments = [] of Array(Piece)
      segments << [Piece.plain(lead.text, PERCENT_STYLE)] if lead
      segments << [Piece.new(Progress.bar(bar_width, done, @color, @charset), bar_width)] if bar_width > 0
      unless rest.empty?
        run = [] of Piece
        rest.each_with_index do |field, index|
          run << Piece.plain(separator, SEPARATOR_STYLE) if index > 0
          run << Piece.plain(field.text)
        end
        segments << run
      end
      if name && name_width > 0
        segments << [Piece.plain(Progress.scroll(name, name_width, elapsed), NAME_STYLE)]
      end

      pieces = [] of Piece
      segments.each_with_index do |segment, index|
        pieces << Piece.plain(" ") if index > 0
        pieces.concat segment
      end
      paint pieces
    end

    # Wrap each piece in its style when color is on; otherwise join the text.
    private def paint(pieces : Array(Piece)) : String
      String.build do |str|
        pieces.each do |piece|
          style = piece.style
          if @color && style
            str << "\e[" << style << 'm' << piece.text << RESET
          else
            str << piece.text
          end
        end
      end
    end

    private def separator : String
      @charset.ascii? ? " | " : " · "
    end

    # A bar `width` columns wide, `done` of it filled.
    #
    # With color the filled part and the track are background colors, so they
    # meet with no gap, and a unicode charset gives the leading cell one of the
    # eighth-blocks for sub-column resolution. Without color there is no
    # background to lean on and the bar falls back to glyphs.
    def self.bar(width : Int32, done : Float64, color : Bool = false, charset : Charset = Charset::Unicode) : String
      return "" if width < 1
      exact = width * done.clamp(0.0, 1.0)
      full = exact.floor.to_i
      full = width if full > width
      eighths = ((exact - full) * 8).to_i.clamp(0, 7)
      partial = charset.unicode? && full < width && eighths > 0 ? 1 : 0

      if color
        String.build do |str|
          str << "\e[" << FILLED_STYLE << 'm' << " " * full << RESET if full > 0
          str << "\e[" << PARTIAL_STYLE << 'm' << EIGHTHS[eighths - 1] << RESET if partial > 0
          rest = width - full - partial
          str << "\e[" << TRACK_STYLE << 'm' << " " * rest << RESET if rest > 0
        end
      elsif charset.ascii?
        (ASCII_FILL.to_s * full) + (ASCII_EMPTY.to_s * (width - full))
      else
        String.build do |str|
          str << FILL.to_s * full
          str << EIGHTHS[eighths - 1] if partial > 0
          str << EMPTY.to_s * (width - full - partial)
        end
      end
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

    # The count the pair does not already carry: lines beside a byte total, bytes
    # beside a line total. Repeating the quantity the pair measures would print
    # the same number twice.
    private def counterpart(bytes : Int64, lines : Int64) : String
      if @total.bytes
        "#{Progress.human_count(lines)} ln"
      else
        Progress.human_bytes(bytes)
      end
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
