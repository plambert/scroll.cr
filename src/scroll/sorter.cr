module Scroll
  # A parsed `--sort-by` key selector. Two concrete grammars:
  #
  # * `Field`   — an integer, the Nth whitespace-separated column (1-based).
  # * `Pattern` — a slash-delimited `/regex/`; the key is the named capture
  #   `sort` if present, else the first capture group, else the whole match.
  #
  # `nil` (no `--sort-by`) means the key is the whole line; that case is handled
  # by the `Sorter`, not represented here.
  abstract struct SortKey
    # Extract the key substring from one line. Returns `""` when the selector
    # does not apply to the line (out-of-range column, or a non-matching regex);
    # an empty key sorts first (ascending) / into the non-numeric bucket.
    abstract def extract(line : String) : String

    # An integer 1-based whitespace column.
    struct Field < SortKey
      getter index : Int32

      def initialize(@index : Int32)
      end

      def extract(line : String) : String
        line.split[index - 1]? || ""
      end
    end

    # A slash-delimited PCRE2 pattern, with named/first/whole capture precedence.
    struct Pattern < SortKey
      getter regex : Regex

      def initialize(@regex : Regex)
      end

      def extract(line : String) : String
        return "" unless match = regex.match(line)
        # `match[1]?` is nil when the regex has no capturing groups, so the
        # fallthrough to `match[0]` (the whole match) is required.
        match["sort"]? || match[1]? || match[0]
      end
    end
  end

  # A `--sort` comparison key with a defined total order over numeric and
  # non-numeric lines. Lexical keys are represented as non-numeric keys (raw
  # string comparison), so a single concrete type covers both `--sort` and
  # `--human`. Under `--human`, non-numeric lines sort *before* numeric ones
  # (ascending), lexically among themselves; numeric lines sort by value.
  struct HumanKey
    include Comparable(HumanKey)

    getter? numeric : Bool
    getter value : Float64 # meaningful only when numeric
    getter raw : String    # the key-source string, for non-numeric/tie order

    # Base for byte-suffix magnitudes (GNU `sort -h` uses 1024).
    BASE = 1024.0

    # Byte-suffix value: non-negative magnitude + unit letter (+ optional B).
    # The `(?<!-)` lookbehind enforces that byte values are never negative. The
    # trailing delimiter is a lookahead so it is not consumed into the match.
    HUMAN = /(?<!-)(\d+(?:\.\d+)?)([Bb]|[kKmMgGtT][Bb]?)(?=[^\w\d]|$)/

    # A leading `-` is a sign only at a boundary; `(?<![\w.])` keeps an embedded
    # `-` (as in a token like `a-5k`) a separator, so the digits parse positive
    # while a standalone `-5` / `-1.5` still parses negative.
    FLOAT = /(?<![\w.])-?\d+\.\d+/
    INT   = /(?<![\w.])-?\d+/

    # Unit letter (lowercased) => exponent applied to BASE.
    EXPONENTS = {'b' => 0, 'k' => 1, 'm' => 2, 'g' => 3, 't' => 4}

    def initialize(@numeric : Bool, @value : Float64, @raw : String)
    end

    # A non-numeric (lexical) key over the raw string.
    def self.lexical(source : String) : HumanKey
      new(false, 0.0, source)
    end

    # Parse one key-source string into a HumanKey. Tries the three numeric
    # patterns and takes the leftmost match; ties in position break by
    # precedence human > float > int (so `1.5k` parses as bytes, not `1.5`).
    def self.parse(source : String) : HumanKey
      human = HUMAN.match(source)
      float = FLOAT.match(source)
      int = INT.match(source)

      best_begin = Int32::MAX
      best_rank = Int32::MAX
      best_value = 0.0

      if human && (begins = human.begin(0)) < best_begin
        best_begin = begins
        best_rank = 0
        best_value = human_value(human)
      end
      if float && float_better?(float.begin(0), best_begin, 1, best_rank)
        best_begin = float.begin(0)
        best_rank = 1
        best_value = float[0].to_f
      end
      if int && float_better?(int.begin(0), best_begin, 2, best_rank)
        best_rank = 2
        best_value = int[0].to_f
      end

      return lexical(source) if best_rank == Int32::MAX
      new(true, best_value, source)
    end

    # A candidate wins if it begins earlier, or begins at the same index with a
    # higher precedence (lower rank).
    private def self.float_better?(begins : Int32, best_begin : Int32, rank : Int32, best_rank : Int32) : Bool
      begins < best_begin || (begins == best_begin && rank < best_rank)
    end

    private def self.human_value(match : Regex::MatchData) : Float64
      magnitude = match[1].to_f
      exponent = EXPONENTS[match[2][0].downcase]? || 0
      magnitude * (BASE ** exponent)
    end

    def <=>(other : HumanKey) : Int32
      if numeric? && other.numeric?
        # Float64#<=> is Int32? (NaN); our values are parsed digits, never NaN.
        (value <=> other.value) || 0
      elsif numeric? == other.numeric? # both non-numeric
        raw <=> other.raw              # lexical among non-numbers
      else
        numeric? ? 1 : -1 # non-numeric sorts BEFORE numeric
      end
    end
  end

  # Reorders the retained tail window for STDERR *display only*. It is applied
  # between `tail.snapshot` and `renderer.draw`, and never touches STDOUT or the
  # `Tail`'s input-order invariants.
  #
  # Design note (plan alignment): under sorting the tool's normal "never slow
  # STDOUT" priority is intentionally relaxed. STDOUT, when present, is still an
  # input-order passthrough (byte identity preserved) — it is just no longer the
  # performance priority while the display is being sorted over the full window.
  # The headline use case is sort + `--file`/`-f` follow with no STDOUT at all.
  class Sorter
    def initialize(@sort : Bool, @reverse : Bool, @human : Bool, @sort_by : SortKey?)
    end

    # The comparable key for one line, exposed so `SortWindow` can track the
    # top-N without re-implementing key extraction. `--reverse` is *not* baked in
    # here — callers apply it to the comparison.
    def key(line : String) : HumanKey
      key_for line
    end

    def reverse? : Bool
      @reverse
    end

    # Reorder for display only. Returns the same array (identity) when no
    # ordering is requested, so the common path adds zero overhead.
    def order(lines : Array(String)) : Array(String)
      return lines unless @sort || @reverse
      return reverse_only(lines) unless @sort
      sort_lines(lines)
    end

    private def reverse_only(lines : Array(String)) : Array(String)
      lines.reverse
    end

    # Stable decorate-sort: Crystal's `Array#sort` is introsort (not stable), so
    # each line carries its original index as the final tiebreaker. Equal keys
    # keep input order in both ascending and descending directions.
    private def sort_lines(lines : Array(String)) : Array(String)
      decorated = lines.map_with_index { |line, index| {key_for(line), index, line} }
      decorated.sort! do |a, b|
        cmp = a[0] <=> b[0]
        cmp = -cmp if @reverse            # invert the key comparison, not the array
        cmp.zero? ? (a[1] <=> b[1]) : cmp # index ascending => stable ties
      end
      decorated.map(&.[2])
    end

    # The comparable key for one line. Under `--human` it is the parsed numeric
    # key; otherwise a lexical key over the raw key-source string.
    private def key_for(line : String) : HumanKey
      source = key_source line
      @human ? HumanKey.parse(source) : HumanKey.lexical(source)
    end

    private def key_source(line : String) : String
      if selector = @sort_by
        selector.extract(line)
      else
        line
      end
    end
  end
end
