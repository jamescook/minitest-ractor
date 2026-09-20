# frozen_string_literal: true

require "etc"
require "minitest"
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
      attr_reader :size

      def initialize(size = self.class.default_size)
        @size        = size
        @workers     = []
        @idle        = []
        @pending     = {}
        @outstanding = 0
      end

      def self.default_size
        Etc.nprocessors
      end

      def start
        ShareableConstants.apply!

        @results = ::Ractor::Port.new
        @workers = Array.new(size) { |id| spawn(id) }
        @idle    = (0...size).to_a
        self
      end

      # Minitest pushes one job per test method: [klass, method_name, reporter].
      def <<(work)
        klass, method_name, reporter = work

        reporter.prerecord klass, method_name
        collect_one if @idle.empty?

        id = @idle.shift
        @pending[id] = reporter
        @workers[id].send [klass, method_name]
        @outstanding += 1
        self
      end

      def shutdown
        collect_one while @outstanding.positive?

        @workers.each { |worker| worker.send nil }
        @workers.each(&:value)

        @workers = []
        @idle    = []
        self
      end

      private

      def spawn(id)
        ::Ractor.new(@results, id) do |home, me|
          while (job = ::Ractor.receive)
            klass, method_name = job
            result = klass.new(method_name).run

            # Minitest keeps a metadata hash on a Result for exactly this: plain data attached
            # in passing that reaches the reporter intact. Marshal-able only, which an Integer
            # is, and which is the same constraint as crossing back out of a Ractor.
            result.metadata[:minitest_ractor_worker] = me

            home.send [me, result]
          end
        end
      end

      # Blocks until one worker reports. Recording happens HERE, in the main Ractor, because
      # that is the only place the reporter exists.
      def collect_one
        id, result = @results.receive
        @outstanding -= 1
        @idle << id
        @pending.delete(id).record result
      end
    end
  end
end
