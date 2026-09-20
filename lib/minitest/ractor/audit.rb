# frozen_string_literal: true

require "minitest"
require_relative "../ractor"
require_relative "executor"
require_relative "inventory"

module Minitest
  module Ractor
    # Loads somebody else's test suite and runs it in a pool of Ractors, without their having
    # changed a line of it.
    #
    # This is the mode the gem is most useful in: point it at a checkout nobody has prepared —
    # no parallelize_me!, no Gemfile entry, no edits — and get back an inventory of what is not
    # Ractor-safe. It is also the mode that fights Minitest hardest, for one reason.
    #
    # THE AUTORUN PROBLEM, AND THE UNSUPPORTED HACK THAT SOLVES IT. Test files require
    # "minitest/autorun", which installs an at_exit hook that runs the whole suite. Load those
    # files and run them yourself and you get TWO runs: yours, then minitest's afterwards, the
    # normal way, printing its summary last and burying the real output underneath.
    #
    # Minitest guards that hook with a bare class variable and offers no accessor, no option and
    # no environment variable. So the only lever is to claim the hook is already installed, which
    # stops it being installed at all:
    #
    #   Minitest.class_variable_set :@@installed_at_exit, true
    #
    # That is somebody else's private state and it will break one day. It is confined to
    # .silence_autorun! below, and to this file, for the same reason the Minitest constant patch
    # is confined to one file: when it breaks, there is one place to look.
    class Audit
      # Both conventions, because an unprepared suite follows whichever its author preferred.
      PATTERNS = %w[test_*.rb *_test.rb].freeze

      class NothingToRun < StandardError; end

      # MUST BE CALLED BEFORE THE FIRST TARGET FILE IS LOADED, and there is no way to check that
      # from here. Once minitest/autorun has been required the hook is installed and nothing can
      # take it back, so the executable calls this as its first act.
      #
      # Idempotent and harmless in a process that already ran autorun: the flag is already true
      # and setting it again changes nothing.
      def self.silence_autorun!
        # Not our class variable to redesign — it is minitest's, and reaching for it is the
        # entire point of this method.
        ::Minitest.class_variable_set :@@installed_at_exit, true # rubocop:disable Style/ClassVars
      end

      attr_reader :paths

      def initialize(paths, workers: nil, seed: 42, limit: Inventory::DEFAULT_LIMIT)
        @paths   = Array(paths)
        @workers = workers || Executor.default_size
        @seed    = seed
        @limit   = limit
      end

      # Every test file under the given paths. A path may be a file or a directory.
      def files
        @paths.flat_map do |path|
          if File.directory?(path)
            PATTERNS.flat_map { |pattern| Dir[File.join(path, "**", pattern)] }
          else
            [path]
          end
        end.uniq.sort
      end

      # Returns an Inventory. Raises NothingToRun rather than reporting a confident nothing,
      # which is the same refusal the plugin's pre-flight makes for the same reason.
      def run
        loaded = load_files
        raise NothingToRun, "no test files under #{@paths.join(', ')}" if loaded.empty?

        # runnable_methods srands with it, and it is nil until somebody sets it. Fixed by default
        # so two audits of the same checkout dispatch in the same order.
        ::Minitest.seed = @seed

        jobs = jobs_in suites
        raise NothingToRun, "loaded #{loaded.size} files but found no tests" if jobs.empty?

        Inventory.from dispatch(jobs), limit: @limit
      end

      # What was loaded, and what refused to load. A file that raises on require is not a finding
      # about Ractors and must not be reported as one, but it cannot be silently dropped either.
      attr_reader :load_failures

      private

      def load_files
        @load_failures = []

        files.each_with_object([]) do |file, loaded|
          require File.expand_path(file)
          loaded << file
        rescue StandardError, LoadError, SyntaxError => e
          @load_failures << [file, "#{e.class}: #{e.message.lines.first.to_s.strip}"]
        end
      end

      def suites
        ::Minitest::Runnable.runnables.select do |runnable|
          runnable.respond_to?(:runnable_methods) && !runnable.runnable_methods.empty?
        end
      end

      # An unprepared suite calls parallelize_me! nowhere, so nothing here is marked parallel.
      # It does not matter: this dispatches to the executor itself rather than going through
      # Minitest.run, so run_order only decides the order within a class. Said plainly because
      # the opposite is easy to assume — the plugin path DOES depend on parallelize_me!, and
      # this one deliberately does not.
      def jobs_in(runnables)
        runnables.flat_map do |runnable|
          runnable.runnable_methods.map { |name| [runnable, name] }
        end
      end

      def dispatch(jobs)
        collector = Collector.new
        executor  = Executor.new @workers

        executor.start
        jobs.each { |klass, name| executor << [klass, name, collector] }
        executor.shutdown

        collector.results
      end

      # Collects and interprets nothing. The Inventory does the interpreting.
      class Collector < ::Minitest::AbstractReporter
        attr_reader :results

        def initialize
          super
          @results = []
        end

        def prerecord(_klass, _name); end

        def record(result)
          @results << result
        end
      end
    end
  end
end
