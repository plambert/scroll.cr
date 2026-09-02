module Scroll
  # Drives the terminal's own progress indicator — the one a taskbar, dock icon,
  # or tab decoration shows — with OSC 9;4:
  #
  #     ESC ] 9 ; 4 ; <state> ; <percent> BEL
  #
  # State 1 carries a percentage, 3 means the run is indeterminate (no size to
  # measure against), and 0 takes the indicator away. Only terminals that name
  # themselves as implementing it are driven; a terminal that does not know the
  # sequence can otherwise print the tail of it into the display.
  class TerminalProgress
    REMOVE        = 0
    NORMAL        = 1
    INDETERMINATE = 3

    @last : {Int32, Int32}?

    def initialize(@io : IO)
      @last = nil
    end

    # Report `fraction` of the run done, or an indeterminate run when it is nil.
    # A repeat of the same state is dropped: the indicator moves in whole
    # percent, and the display ticks far more often than that.
    def report(fraction : Float64?) : Nil
      state = if fraction
                {NORMAL, (fraction.clamp(0.0, 1.0) * 100).round.to_i}
              else
                {INDETERMINATE, 0}
              end
      return if state == @last
      @last = state
      emit state[0], state[1]
    end

    # Take the indicator away, leaving the terminal as the run found it. Does
    # nothing if nothing was ever reported, and is safe from an at_exit hook.
    def clear : Nil
      return if @last.nil?
      @last = nil
      emit REMOVE, 0
    end

    private def emit(state : Int32, value : Int32) : Nil
      @io << "\e]9;4;" << state << ';' << value << '\a'
      @io.flush
    rescue IO::Error
      # Terminal already gone; nothing to report to.
    end
  end
end
