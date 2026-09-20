# frozen_string_literal: true

require "minitest"
require_relative "../ractor"
require_relative "executor"
require_relative "reporter"

module Minitest
  module Ractor
    # Decides whether this gem should take over a run, and does it. Kept apart from
    # minitest/ractor_plugin.rb, which is only the file RubyGems finds, so that the decisions can
    # be tested without loading anything into the world.
    #
    # WHY OPT-IN. On minitest 5 it was survival: load_plugins required minitest/*_plugin.rb from
    # every installed gem on every run, so acting at load time would have hijacked suites that
    # had never heard of this one. Minitest 6 dropped that call, so now only people who required
    # this gem by name are affected — and requiring a gem still is not the same as wanting every
    # test in a Ractor today, so the flag and the env var remain the only two ways in.
    #
    # WHY THERE ARE TWO WAYS IN, AND THEY ARE NOT INTERCHANGEABLE. --ractor is the one to use and
    # the one that reads well. But a flag is not visible until Minitest.run parses the command
    # line, which is long after the test files loaded, and under MT_CPU=1 that is too late to
    # matter — see #unreachable!. An environment variable is readable at plugin LOAD time, before
    # any test file exists, which is the only thing that can get in front of parallelize_me!.
    module Plugin
      OPT_IN  = "MT_RACTOR"
      WORKERS = "MT_RACTOR_WORKERS"
      THREADS = "MT_CPU"

      # Installs the pool before any test file loads. The only route that survives MT_CPU=1.
      #
      # Only ever fills an empty slot. Somebody who has installed their own executor has said
      # something about how they want their tests run, and an env var picked up by a gem they
      # may not remember installing is not a good enough reason to overrule it.
      def self.install_at_load(env = ENV)
        return :not_asked unless opted_in? env
        return :left_alone unless ::Minitest.parallel_executor.nil?

        ::Minitest.parallel_executor = Executor.new workers(env)
        :installed
      end

      # Called from plugin_ractor_init, inside Minitest.run, once the command line has been read.
      # Late enough that --ractor is finally visible, and still early enough to catch every job:
      # parallelize_me! only installs Parallel::Test::ClassMethods, whose run reads
      # Minitest.parallel_executor at DISPATCH time rather than remembering one.
      def self.init(options, env = ENV, reporter: ::Minitest.reporter)
        if declined? options
          restore_thread_executor env if ractor_pool_installed?
          return :declined
        end

        return :not_asked unless asked_for? options, env

        unreachable!(env) unless reachable? env

        ::Minitest.parallel_executor = Executor.new workers(env) unless ractor_pool_installed?
        install_reporter reporter, options
        :installed
      end

      # Idempotent, and by checking rather than by remembering. A gem that demands the code under
      # test hold no shared mutable state should not keep a "have I run yet" flag of its own, and
      # the state it would be tracking is readable anyway.
      def self.install_reporter(reporter, options)
        return unless reporter
        return if reporter.respond_to?(:reporters) && reporter.reporters.any?(Reporter)

        reporter << Reporter.new(io: options[:io] || $stdout)
      end

      def self.asked_for?(options, env = ENV)
        options[:ractor] || opted_in?(env)
      end

      # --no-ractor. Distinct from "not asked": nil means nobody said anything, false means
      # somebody said no, and only the second one outranks MT_RACTOR.
      def self.declined?(options)
        options[:ractor] == false
      end

      # Puts back the thread executor minitest would have built, replacing ours.
      #
      # Needed because --no-ractor can only be read after MT_RACTOR has already installed the
      # pool at load time, and parallelize_me! has already seen it and made the classes parallel.
      # That cannot be taken back: the classes now dispatch through
      # Minitest.parallel_executor whatever it holds. Leaving ours there would run everything in
      # Ractors after somebody asked for that not to happen, and emptying the slot would dispatch
      # into nil.
      #
      # The thread count is the same sum minitest.rb does, so this is what would have been there
      # rather than a guess at it. Floored at one: under MT_CPU=1 minitest builds no executor at
      # all, but by now something has to answer.
      def self.restore_thread_executor(env = ENV)
        threads = (env[THREADS] || Etc.nprocessors).to_i

        ::Minitest.parallel_executor = ::Minitest::Parallel::Executor.new [threads, 1].max
      end

      def self.opted_in?(env = ENV)
        truthy? env[OPT_IN]
      end

      # "MT_RACTOR=0" and "MT_RACTOR=" mean somebody turned it off, and having those switch it on
      # is the kind of thing people spend an afternoon on.
      def self.truthy?(value)
        return false if value.nil?

        !["", "0", "false", "no"].include?(value.strip.downcase)
      end

      def self.ractor_pool_installed?
        ::Minitest.parallel_executor.is_a? Executor
      end

      def self.workers(env = ENV)
        count = env[WORKERS].to_i
        count.positive? ? count : Executor.default_size
      end

      # Whether a Ractor can still be reached by the time init runs.
      #
      # Under MT_CPU=1 minitest builds no default executor at all ("if n_threads > 1"), so
      # parallelize_me! hit "return unless Minitest.parallel_executor" and did nothing — no
      # ClassMethods, no parallel run_order. Swapping the executor now changes nothing, because
      # there is no longer anything that would ask for it.
      def self.reachable?(env = ENV)
        threads = env[THREADS]

        threads.nil? || threads.to_i > 1 || ractor_pool_installed?
      end

      # THE ONE CASE WHERE FAILING LOUDLY IS THE ENTIRE POINT.
      #
      # Left alone, this combination runs the suite in the main Ractor and reports a cheerful
      # "0 failures" — a green run claiming an isolation proof that was never attempted, which is
      # indistinguishable from success and worse than any crash.
      def self.unreachable!(env = ENV)
        raise ProofNotAttempted, <<~MESSAGE
          #{THREADS}=#{env[THREADS]} switched minitest's parallel executor off before your test
          files loaded, so parallelize_me! did nothing and no test will go near a Ractor. Asking
          for --ractor now cannot undo that: the classes never became parallel, and there is
          nothing left to redirect.

          Use the environment variable instead, which is read early enough to get in front of it:

              #{THREADS}=#{env[THREADS]} #{OPT_IN}=1 <your test command>

          Refusing to run rather than report a passing suite that proved nothing.
        MESSAGE
      end

      private_class_method :truthy?, :unreachable!
    end
  end
end
