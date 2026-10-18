# frozen_string_literal: true

module Squishling
  # How many times each squished method has been called with models to rotate between (see ModelPath: steps tied on
  # priority). The count is the call's turn: each tier of tied models starts that many steps further along, so
  # successive calls give every model an even share of the first attempts. Counted per class and method, across
  # threads.
  module Rotation
    # class => { method name => calls so far }. Weak keys, so classes replaced by code reloading can be collected.
    COUNTS = ObjectSpace::WeakKeyMap.new
    COUNTS_LOCK = Mutex.new
    private_constant :COUNTS, :COUNTS_LOCK

    class << self
      # This call's turn, counting from 0, and counts it.
      def advance(klass, name)
        COUNTS_LOCK.synchronize do
          counts = (COUNTS[klass] ||= {})
          turn = counts.fetch(name, 0)
          counts[name] = turn + 1
          turn
        end
      end
    end
  end
end
