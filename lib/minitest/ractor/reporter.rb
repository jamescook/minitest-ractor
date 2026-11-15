# frozen_string_literal: true

require "minitest"
require_relative "inventory"

module Minitest
  module Ractor
    # Collects every result and prints the inventory when the run ends.
    #
    # Added to Minitest's CompositeReporter during init_plugins, which is the one moment
    # Minitest.reporter is set for exactly this purpose. Minitest calls #report on every reporter
    # at the end of the run, after the usual summary, so the inventory lands last.
    #
    # It reports and never judges: the findings already failed their tests, and having this
    # object also decide the exit status would count the same problem twice.
    class Reporter < Minitest::AbstractReporter
      attr_reader :results

      def initialize(io: $stdout, limit: Inventory::DEFAULT_LIMIT)
        super()
        @io      = io
        @limit   = limit
        @results = []
      end

      def record(result)
        @results << result
      end

      def report
        @io.puts
        @io.puts inventory.to_s
      end

      # POST-FLIGHT, and the last word on whether a proof was attempted.
      #
      # Pre-flight can be fooled: an executor replaced after init_plugins, a filter that selects
      # only serial classes, a cause nobody has thought of. This looks at what actually happened
      # instead — every result the executor produced carries the worker that ran it — so it
      # catches reasons that were never enumerated.
      #
      # Minitest ANDs passed? across every reporter, so returning false is what makes the run
      # exit non-zero. It judges ONLY whether anything reached a Ractor: failing tests are
      # minitest's business and already counted, and counting them here would count them twice.
      #
      # A run where every test said runs_on_the_main_ractor! passes. Each one asked to stay home
      # and was told yes, so nothing went wrong, and running one file of such tests on its own is
      # ordinary. The report still says the run proved nothing. A test that stayed home without
      # asking still fails the run, even beside opt-outs, because that is the mistake this is for.
      def passed?
        inventory = self.inventory
        !inventory.proved_nothing? || inventory.everything_opted_out?
      end

      def inventory
        Inventory.from @results, limit: @limit
      end
    end
  end
end
