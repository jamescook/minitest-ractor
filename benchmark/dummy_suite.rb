# frozen_string_literal: true

# A few hundred tests over a library that does nothing, for timing executors against each other.
#
# Defines the classes and stops. No autorun: the runner drives the executors directly, the way
# Minitest would, and an at_exit hook would run the whole suite again underneath the benchmark.
#
# WHY THE TESTS ARE BUILT WITH class_eval AND A STRING rather than define_method. A method
# defined from a block is a method defined from a Proc, and calling one from a worker raises
# "defined with an un-shareable Proc in a different Ractor" — Ruby refuses before it even enters
# the method, so the backtrace points at minitest's dispatch and not at anything you wrote. That
# exact shape accounted for 14 findings in the first real suite this was pointed at. A string
# eval compiles an ordinary method and sidesteps it.
#
# Size and weight are adjustable, because how the numbers move with them is the whole question:
#
#   BENCH_CLASSES=20 BENCH_TESTS=20 BENCH_SLEEPERS=5 BENCH_WORK=20

require "minitest"
require_relative "dummy"

module DummySuite
  CLASSES   = Integer(ENV.fetch("BENCH_CLASSES", 20))
  PER_CLASS = Integer(ENV.fetch("BENCH_TESTS", 20))
  SLEEPERS  = Integer(ENV.fetch("BENCH_SLEEPERS", 5))

  # How much CPU each test burns, as the argument to a deliberately naive fib. It is
  # exponential, so this is a coarse dial. Tests that finish in microseconds measure the harness
  # rather than the pool.
  WORK = Integer(ENV.fetch("BENCH_WORK", 20))

  # Tests that wait rather than work. Threads are good at waiting, so a suite made only of
  # CPU-bound tests would flatter the pool.
  class Sleepy < Minitest::Test
    SLEEPERS.times do |index|
      class_eval <<~RUBY, __FILE__, __LINE__ + 1
        # def test_waits_0
        #   sleep 0.002
        #
        #   assert_operator Dummy.checksum("abc"), :>=, 0
        # end
        def test_waits_#{index}
          sleep 0.002

          assert_operator Dummy.checksum("abc"), :>=, 0
        end
      RUBY
    end
  end

  def self.build
    Array.new(CLASSES) do |klass_index|
      klass = Class.new Minitest::Test
      const_set "Batch#{klass_index}", klass

      PER_CLASS.times do |test_index|
        klass.class_eval <<~RUBY, __FILE__, __LINE__ + 1
          # def test_case_0
          #   assert_equal 20, Dummy.fib(20) - Dummy.fib(20) + 20
          #   assert_operator Dummy.checksum(Dummy.phrase(0)), :>=, 0
          #   assert_equal "X!", Dummy.shout("x")
          #   assert_operator Dummy.vowels_in(Dummy.phrase(0)), :>=, 0
          # end
          def test_case_#{test_index}
            assert_equal #{WORK}, Dummy.fib(#{WORK}) - Dummy.fib(#{WORK}) + #{WORK}
            assert_operator Dummy.checksum(Dummy.phrase(#{test_index})), :>=, 0
            assert_equal "X!", Dummy.shout("x")
            assert_operator Dummy.vowels_in(Dummy.phrase(#{test_index})), :>=, 0
          end
        RUBY
      end

      klass
    end
  end

  # Every [class, method] pair to dispatch, sleepers included. Deliberately not memoised on this
  # module: a file whose job is to be an example of Ractor-safe code has no business keeping
  # state on a module, even state no worker would ever reach. The runner calls this once and
  # holds the result.
  def self.jobs
    (build + [Sleepy]).flat_map do |klass|
      klass.runnable_methods.map { |name| [klass, name] }
    end
  end
end
