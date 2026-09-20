# frozen_string_literal: true

require "minitest"

module Minitest
  module Ractor
    # Minitest keeps three mutable objects in constants, and a non-main Ractor may not read a
    # constant whose value is mutable. Until these are shareable, a test cannot run in a worker
    # at all — it raises Ractor::IsolationError before reaching its first assertion.
    #
    # Exactly three, found by running a test in a Ractor and making shareable whatever it
    # complained about until it stopped complaining. probes/ractor_minitest_depth.rb is that
    # search; re-run it against a new Minitest to check the list has not grown.
    #
    # This patches Minitest in place, which is not something to do lightly. It is done anyway
    # because the alternative is waiting on an upstream change that may never come, and nothing
    # here depends on that change ever being accepted. The patch is confined to this file and
    # to these three names.
    #
    # Ractor.make_shareable, never freeze: an Array of unfrozen Strings is frozen and still off
    # limits. Shareable means frozen all the way down.
    module ShareableConstants
      NAMES = %i[PASSTHROUGH_EXCEPTIONS SETUP_METHODS TEARDOWN_METHODS].freeze

      class MissingConstant < StandardError; end

      # Idempotent: a constant that is already shareable is left alone, so requiring this file
      # twice, or calling apply! after Minitest has already been patched, costs nothing.
      def self.apply!
        NAMES.each { |name| make_shareable name }
        self
      end

      def self.applied?
        NAMES.all? { |name| ::Ractor.shareable?(::Minitest::Test.const_get(name)) }
      end

      def self.make_shareable(name)
        unless ::Minitest::Test.const_defined?(name, false)
          raise MissingConstant,
                "Minitest::Test::#{name} is gone. This Minitest (#{::Minitest::VERSION}) is " \
                "not one minitest-ractor knows how to patch; re-run the probe to find the " \
                "constants it needs now."
        end

        value = ::Minitest::Test.const_get name
        return if ::Ractor.shareable?(value)

        shareable = ::Ractor.make_shareable value
        ::Minitest::Test.send :remove_const, name
        ::Minitest::Test.const_set name, shareable
      end
      private_class_method :make_shareable
    end
  end
end
