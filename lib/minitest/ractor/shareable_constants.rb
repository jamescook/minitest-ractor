# frozen_string_literal: true

require "minitest"

module Minitest
  module Ractor
    # Minitest keeps mutable objects in constants and on module instance variables, and a worker
    # Ractor can reach neither. Until they are shareable a test cannot run in a worker at all, or
    # can run but cannot report what happened to it.
    #
    # THIS LIST WAS THREE NAMES ONCE, and that was wrong. Three is what a single trivial test
    # reaches; a real suite of 3400 reached five more, and the missing ones did not announce
    # themselves — one of them quietly replaced every failure's true cause with its own. So the
    # list below comes from probes/minitest_census.rb, which walks the whole namespace instead
    # of being remembered. Re-run it against a new Minitest rather than trusting this file.
    #
    # This patches Minitest in place, which is not done lightly. It is done because the
    # alternative is waiting on an upstream change that may never come, and nothing here depends
    # on that change ever being accepted. The patch is confined to this file.
    #
    # Ractor.make_shareable, never freeze: an Array of unfrozen Strings is frozen and still off
    # limits. Shareable means frozen all the way down.
    module ShareableConstants
      CONSTANTS = {
        "Minitest" => %i[VERSION],
        "Minitest::Assertions" => %i[NO_RE_MSG UNDEFINED],
        "Minitest::Reportable" => %i[BASE_DIR],
        "Minitest::Runnable" => %i[SIGNALS],
        "Minitest::Spec" => %i[TYPES],
        "Minitest::Spec::DSL" => %i[TYPES],
        "Minitest::Test" => %i[PASSTHROUGH_EXCEPTIONS SETUP_METHODS TEARDOWN_METHODS]
      }.freeze

      # A test cannot run in a worker at all without these three, so one going missing means this
      # is not a Minitest we know how to patch and saying so early beats failing obscurely inside
      # a worker. Everything else is skipped when absent: Spec is only loaded if asked for.
      REQUIRED = "Minitest::Test"

      # Left alone deliberately, though the census finds them unshareable too:
      #
      #   Minitest @parallel_executor  us. A worker must never reach the thing scheduling it.
      #   Minitest::Test @io_lock      a Mutex, which cannot be made shareable by anything.
      #   Minitest @extensions         appended to as plugins register; freezing it races with
      #                                that, and only the main Ractor ever reads it.
      #   Minitest @info_signal        main Ractor only.
      #
      # A worker reaching any of these is a bug in this gem, not something to paper over here.
      IVARS = ["Minitest.backtrace_filter"].freeze

      class MissingConstant < StandardError; end

      # Idempotent: anything already shareable is left alone, so calling this twice costs
      # nothing and calling it after somebody else has patched Minitest costs nothing either.
      def self.apply!
        record = {}

        CONSTANTS.each do |owner_name, names|
          owner = resolve owner_name
          next unless owner

          names.each do |name|
            record["#{owner_name}::#{name}"] = share_constant(owner, owner_name, name)
          end
        end

        record["Minitest.backtrace_filter"] = share_backtrace_filter
        @patched = ::Ractor.make_shareable record
        self
      end

      def self.applied?
        CONSTANTS.all? do |owner_name, names|
          owner = resolve owner_name
          owner.nil? || names.all? do |name|
            !owner.const_defined?(name, false) || ::Ractor.shareable?(owner.const_get(name, false))
          end
        end
      end

      # What apply! did to each name: :made_shareable, :left_alone, or :absent. Worth being able
      # to ask, because this gem edits somebody else's library in place and the first question
      # when Minitest misbehaves is which parts of it are no longer stock.
      #
      # Kept shareable rather than a plain mutable Hash for two reasons. A tool that demands the
      # code under test hold no shared mutable state has no business holding any itself; and a
      # worker can then read this, which it could not otherwise.
      #
      # The rule is narrower than "a Ractor may not touch class ivars", which is how it is
      # usually repeated. A worker may read an instance variable of a class or module perfectly
      # well — what it may not do is get an UNSHAREABLE value out of one, or write one at all.
      # probes/ractor_module_ivar.rb is the demonstration.
      def self.patched
        @patched ||= ::Ractor.make_shareable({})
      end

      def self.report
        lines = patched.reject { |_, what| what == :absent }
                       .map { |path, what| format("  %<path>-46s %<what>s", path:, what:) }
        ["minitest-ractor patched Minitest #{::Minitest::VERSION}:", *lines].join("\n")
      end

      def self.resolve(name)
        Object.const_get name
      rescue NameError
        nil
      end

      def self.share_constant(owner, owner_name, name)
        unless owner.const_defined?(name, false)
          return :absent unless owner_name == REQUIRED

          raise MissingConstant,
                "#{owner_name}::#{name} is gone. This Minitest (#{::Minitest::VERSION}) is not " \
                "one minitest-ractor knows how to patch; re-run probes/minitest_census.rb to " \
                "find the names it needs now."
        end

        value = owner.const_get name, false
        return :left_alone if ::Ractor.shareable?(value)

        shareable = ::Ractor.make_shareable value
        owner.send :remove_const, name
        owner.const_set name, shareable
        :made_shareable
      end

      # Read while BUILDING A FAILURE MESSAGE rather than while running a test, so it fires only
      # on the failure path — after something has already gone wrong — and the error it raises
      # replaces the real one. Left unpatched it does not merely add failures, it hides them.
      #
      # A frozen BacktraceFilter is enough: #filter reads $DEBUG and ENV["MT_DEBUG"], and a
      # worker may read both (probes/minitest_filter_in_worker.rb).
      def self.share_backtrace_filter
        filter = ::Minitest.backtrace_filter
        return :absent if filter.nil?
        return :left_alone if ::Ractor.shareable?(filter)

        ::Minitest.backtrace_filter = ::Ractor.make_shareable filter
        :made_shareable
      end

      private_class_method :resolve, :share_constant, :share_backtrace_filter
    end
  end
end
