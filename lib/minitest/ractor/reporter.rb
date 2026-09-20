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

      def inventory
        Inventory.from @results, limit: @limit
      end
    end
  end
end
