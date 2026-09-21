# frozen_string_literal: true

require "etc"
require "minitest"
require_relative "error_chain"
require_relative "shareable_constants"

module Minitest
  module Ractor
    # The object Minitest hands work to, one test method at a time. Minitest's own is a pool of
    # threads; this is a pool of Ractors, which is the whole point — a Ractor may not touch
    # mutable state another Ractor can see, so a suite that stays green here holds none.
    #
    # WHY THE MAIN RACTOR DOES THE SCHEDULING. A Ractor::Port has exactly one legal reader: the
    # Ractor that created it. Several workers receiving from one shared port is refused outright
    # ("only allowed from the creator Ractor of this port"), so workers cannot pull from a common
    # queue the way threads pull off a Thread::Queue. Instead each worker reads its own private
    # inbox, this object decides who gets the next test, and every worker reports into one
    # results port that this object created and may therefore read. Sending TO a port from
    # anywhere is fine; only receiving is restricted.
    #
    # That puts scheduling here, which is where it wants to be anyway: this is also where the
    # reporter lives, and the reporter must never cross into a worker.
    class Executor
      # 128 + SIGINT, which is what a shell reports for a process stopped by Ctrl+C.
      INTERRUPTED = 130

      attr_reader :size

      # trap_interrupt: is on because the behaviour without it is broken rather than merely
      # different — see #trap_interrupt!. Off is for a library user driving this object directly,
      # who may reasonably want Ctrl+C to mean whatever the rest of their program says it means.
      def initialize(size = self.class.default_size, trap_interrupt: true)
        @size            = size
        @workers         = []
        @idle            = []
        @pending         = {}
        @outstanding     = 0
        @completed       = 0
        @trap_interrupt  = trap_interrupt
      end

      def self.default_size
        Etc.nprocessors
      end

      # Where a failure's backtrace actually lives. Minitest wraps anything that is not an
      # assertion in UnexpectedError, which delegates #backtrace to the error it holds, so
      # setting frames on the wrapper would not stick.
      #
      # A class method rather than an instance one because a worker has to call it too, and a
      # worker cannot reach the executor object — only shareable things, which a class is.
      # Runs one test and always comes back with a Result, whatever the test does.
      #
      # WITHOUT THIS THE POOL HANGS, and a hang is the worst outcome available: CI kills it an
      # hour later with no output at all. Minitest re-raises PASSTHROUGH_EXCEPTIONS —
      # NoMemoryError, SignalException, Interrupt, SystemExit — instead of recording them, so
      # they come straight out of #run, kill the worker, and the result is never sent. The main
      # Ractor then waits on @outstanding for a result that can never arrive. Measured: without
      # this, a test raising one of them hung the pool for ever.
      #
      # So anything that escapes is recorded against the test it escaped from and the worker
      # carries on. That is a deliberate narrowing of Minitest's behaviour: an `exit` inside a
      # test stops a normal run and here becomes an error on that one test. Losing the whole
      # run's output to a deadlock is worse than reporting an unusual error accurately.
      #
      # A class method because a worker has to call it and a worker cannot reach the executor
      # object — only shareable things, which a class is.
      def self.result_for(klass, method_name)
        instance = klass.new method_name

        begin
          instance.run
        rescue Exception => e # rubocop:disable Lint/RescueException
          instance.failures << ::Minitest::UnexpectedError.new(e)
          ::Minitest::Result.from instance
        end
      end

      # Gets a result home, whatever it is carrying.
      #
      # A Ractor::Port COPIES what it sends, and not everything can be copied. Exceptions are
      # already safe without us: Ruby neuters one it cannot copy, and it arrives as a plain
      # RuntimeError reading "Neutered Exception <OriginalClass>: <message>" with its instance
      # variables dropped. So a test raising something exotic costs a little detail and nothing
      # else.
      #
      # METADATA IS THE HOLE. Minitest documents it as "plain (read: marshal-able) data", but
      # that is a docstring, not a check, and a Result holding a Proc there is an ordinary object
      # graph rather than an exception — so it is not neutered, the send raises "allocator
      # undefined for Proc", the worker dies with its job still outstanding, and shutdown waits
      # for a result that can never arrive. Measured, and it hung the pool exactly like a dead
      # worker did.
      #
      # So: try it, then try again without the metadata this gem did not put there, and failing
      # that send a result that says what happened. Losing one test's metadata is a small price;
      # losing the run to a deadlock is not.
      # Nested rather than two rescue clauses on one begin: a raise inside a rescue body
      # propagates, it does not fall through to the next clause.
      def self.deliver(result, home:, worker:, job:)
        home.send [worker, result]
      rescue StandardError => e
        begin
          home.send [worker, stamp(without_foreign_metadata(result), worker)]
        rescue StandardError
          home.send [worker, stamp(undeliverable(job, e), worker)]
        end
      end

      def self.stamp(result, worker)
        result.metadata[:minitest_ractor_worker] = worker
        result
      end

      # Keeps only what the executor itself attached, which is an Integer and Arrays of Strings
      # and therefore always sendable.
      def self.without_foreign_metadata(result)
        carried = result.metadata.slice :minitest_ractor_worker, :minitest_ractor_backtraces
        result.metadata.clear
        result.metadata.merge! carried
        result
      end

      # Last resort: a result that carries nothing but the news. Recorded against the test it
      # came from, so the inventory still names something a person can go and look at.
      def self.undeliverable(job, error)
        klass, method_name = job
        instance = klass.new method_name
        trouble  = RuntimeError.new "The worker could not send the result of this test " \
                                    "(#{error.class}: #{error.message.to_s.lines.first.to_s.strip})"
        trouble.set_backtrace []
        instance.failures << ::Minitest::UnexpectedError.new(trouble)

        ::Minitest::Result.from instance
      end

      def start
        ShareableConstants.apply!
        trap_interrupt!

        @results = ::Ractor::Port.new
        @workers = Array.new(size) { |id| spawn(id) }
        @idle    = (0...size).to_a
        self
      end

      # Minitest pushes one job per test method: [klass, method_name, reporter].
      def <<(work)
        klass, method_name, reporter = work

        reporter.prerecord klass, method_name
        return run_here(klass, method_name, reporter) if opted_out? klass

        collect_one if @idle.empty?

        id = @idle.shift
        @pending[id] = reporter
        @workers[id].send [klass, method_name]
        @outstanding += 1
        self
      end

      # The drain at the top is where an interrupted run spends its time — every test already in
      # flight still has to finish — so the handler stays installed across it and comes off only
      # once there is nothing left to interrupt.
      def shutdown
        collect_one while @outstanding.positive?

        @workers.each { |worker| worker.send nil }
        @workers.each(&:value)

        @workers = []
        @idle    = []
        self
      ensure
        untrap_interrupt!
      end

      private

      # CTRL+C, AND WHAT IT COSTS TO LEAVE IT TO MINITEST.
      #
      # Minitest rescues Interrupt and then carries straight on to parallel_executor.shutdown and
      # reporter.report regardless, so a run stopped a third of the way through still drains
      # every test in flight and then prints every failure it had collected, each with its
      # backtrace, with the inventory underneath. Measured on a 120-test run interrupted at 36:
      # 247 lines and 17KB arriving AFTER the signal. From the prompt it reads as the process
      # ignoring Ctrl+C and then emptying itself into the terminal a moment later.
      #
      # AND THE INVENTORY WOULD BE WRONG, which is the half that matters. That run printed "36 of
      # 36 tests ran in Ractors" — a coverage claim, stated confidently, about a run that was
      # abandoned at 36 of 120. The counts, the coverage line and the NO PROOF check are all
      # claims about a COMPLETE run, and a partial one has no honest version of them. Better to
      # print nothing than to answer "what did this prove" with a number that describes a
      # different run.
      #
      # So the pool owns INT for as long as it is up, and hands it back on the way out.
      def trap_interrupt!
        return unless @trap_interrupt && @previous_handler.nil?

        @previous_handler = Signal.trap("INT") { interrupted! }
      end

      def untrap_interrupt!
        Signal.trap "INT", @previous_handler if @previous_handler
        @previous_handler = nil
      end

      # exit! rather than raising, because raising is precisely what happens already: Interrupt
      # reaches minitest, which rescues it and prints the pile. exit! skips at_exit, so no report
      # runs at all — and it skips flushing too, hence doing that by hand first. The progress dots
      # written so far are worth keeping, since they are how far it got.
      #
      # A second Ctrl+C needs nothing: this one ends the process at the first safe point, and
      # anything queued behind it never gets one.
      #
      # $stderr.puts rather than warn because warn is a NO-OP UNDER -W0, which is the flag every
      # Ractor suite runs with to silence Ruby's experimental notice. Minitest's own "Interrupted.
      # Exiting..." goes through warn and is therefore invisible in exactly the situation it is
      # for. Style/StderrPuts wants warn so that output can be disabled; here being disablable is
      # the defect, since this line is the only explanation of why nothing else printed.
      def interrupted!
        tests   = "#{@completed} test#{'s' unless @completed == 1}"
        message = "\nInterrupted after #{tests}. This run shows no inventory. The counts apply " \
                  "to a complete run only."

        $stdout.flush
        $stderr.puts message # rubocop:disable Style/StderrPuts
        $stderr.flush
        exit! INTERRUPTED
      end

      # A class that said runs_on_the_main_ractor!. Asked rather than assumed, because a runnable
      # need not be a Minitest::Test at all.
      def opted_out?(klass)
        klass.respond_to?(:runs_on_the_main_ractor?) && klass.runs_on_the_main_ractor?
      end

      # Runs it here, in the main Ractor, and records it like any other result.
      #
      # Stamped as having asked, which is what keeps it out of the coverage figure without
      # looking like a test that failed to reach a worker. Those are different things: one is a
      # deliberate narrowing of what the run proves, the other is the proof going missing.
      def run_here(klass, method_name, reporter)
        result = self.class.result_for klass, method_name
        result.metadata[:minitest_ractor_opted_out] = true
        reporter.record result
        @completed += 1
        self
      end

      def spawn(id)
        ::Ractor.new(@results, id) do |home, me|
          while (job = ::Ractor.receive)
            klass, method_name = job
            result = Executor.result_for klass, method_name

            # Minitest keeps a metadata hash on a Result for exactly this: plain data attached
            # in passing that reaches the reporter intact. Marshal-able only, which an Integer
            # is, and which is the same constraint as crossing back out of a Ractor.
            result.metadata[:minitest_ractor_worker] = me

            # A Ractor::Port empties the backtrace of an exception nested in an object graph.
            # Not Ractor copying in general — the same failure keeps its frames across
            # Ractor#value — and not Minitest sanitising it either, since the frames are still
            # here. It is the Port, it happens silently, and the executor cannot use anything
            # else: one legal reader per port is what lets the main Ractor collect from every
            # worker at once.
            #
            # So lift the frames out here, where they still exist, and carry them as plain data.
            # An Array of Strings crosses a Port perfectly well.
            #
            # One list per failure, one entry per link in its cause chain — the cause keeps its
            # message across the Port but loses its frames just like the failure does, and for a
            # masked isolation error the cause's frames are the only ones that name the code at
            # fault.
            result.metadata[:minitest_ractor_backtraces] =
              result.failures.map do |failure|
                ErrorChain.of(failure).map { |error| Array(error.backtrace) }
              end

            Executor.deliver result, home:, worker: me, job:
          end
        end
      end

      # Blocks until one worker reports. Recording happens HERE, in the main Ractor, because
      # that is the only place the reporter exists.
      def collect_one
        id, result = @results.receive
        @outstanding -= 1
        @completed   += 1
        @idle << id
        restore_backtraces result
        @pending.delete(id).record result
      end

      # Put the frames back on the exceptions themselves, rather than leaving them in metadata
      # for a reporter to know about. Every reporter, formatter and plugin downstream already
      # reads #backtrace; a result that has been through a worker should be indistinguishable
      # from one that has not.
      def restore_backtraces(result)
        carried = result.metadata.delete :minitest_ractor_backtraces
        return unless carried

        result.failures.zip(carried) do |failure, chain|
          next unless chain

          ErrorChain.of(failure).zip(chain) do |error, frames|
            error.set_backtrace frames if frames
          end
        end
      end
    end
  end
end
