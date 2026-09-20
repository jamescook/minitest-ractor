# frozen_string_literal: true

module Minitest
  module Ractor
    # One occurrence of the code under test not being Ractor-safe: this test, touching this
    # thing, got a refusal. A finding always belongs to exactly one cause.
    #
    # A finding is not a failure. A test can fail for reasons that have nothing to do with
    # Ractors — a wrong assertion, a genuine bug, a flake — and those are ordinary failures that
    # must never appear in the inventory. The two are kept apart because that separation is the
    # only thing that makes the inventory worth reading.
    class Finding
      attr_reader :cause, :klass, :name, :origin

      def initialize(cause:, klass:, name:, origin: nil)
        @cause  = cause
        @klass  = klass
        @name   = name
        @origin = origin
        freeze
      end

      # Which test this was. Deliberately the only place a test name appears: findings are
      # counted by cause, and a test name is an example of a cause rather than a unit of work.
      def location
        "#{@klass}##{@name}"
      end

      def to_s
        @origin ? "#{location} at #{@origin}" : location
      end
    end
  end
end
