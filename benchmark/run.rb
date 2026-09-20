# frozen_string_literal: true

# Times a Ractor pool against threads and against running the tests one after another.
#
# Measures the executors directly rather than shelling out per run, because a subprocess costs
# more than the thing being measured and benchmark-ips wants many iterations. One iteration here
# is a whole suite: start the pool, dispatch every test, shut it down. That is what a real run
# does, so pool startup is inside the number rather than hidden outside it.
#
#   ruby -I../lib run.rb
#   BENCH_WORK=22 BENCH_CLASSES=40 ruby -I../lib run.rb
#
# EVERY MODE IS CHECKED BEFORE ANYTHING IS TIMED. A pool that fails fast looks wonderful on a
# benchmark, and a suite quietly erroring in a worker would be reported as a speed-up. So each
# executor runs the whole suite once first and has to produce the same number of passes as tests
# dispatched; the benchmark refuses to run otherwise.

require "benchmark/ips"
require "etc"
require "minitest"
require "minitest/ractor"
require "minitest/ractor/executor"
require_relative "dummy_suite"

# Two tiny classes and a script, kept in one file deliberately: this is a benchmark, meant to be
# read top to bottom in one sitting rather than navigated.
# rubocop:disable Style/OneClassPerFile

# Counts, and interprets nothing. Needs #synchronize because Minitest's thread executor calls it
# around every prerecord and record — AbstractReporter provides it.
class Tally < Minitest::AbstractReporter
  attr_reader :passes, :problems

  def initialize
    super
    @passes   = 0
    @problems = []
  end

  def prerecord(_klass, _name); end

  def record(result)
    return @passes += 1 if result.passed?

    said = result.failures.first&.message.to_s.lines.first.to_s.strip
    @problems << "#{result.klass}##{result.name}: #{said}"
  end
end

# Runs the tests one after another in the main Ractor. Not an executor Minitest would use — it
# is the floor the other two are measured against.
class Serially
  def start = self
  def shutdown = self

  def <<(work)
    klass, name, reporter = work
    reporter.prerecord klass, name
    reporter.record klass.new(name).run
    self
  end
end

# rubocop:enable Style/OneClassPerFile

def drive(executor, jobs)
  tally = Tally.new

  executor.start
  jobs.each { |klass, name| executor << [klass, name, tally] }
  executor.shutdown

  tally
end

workers = Integer(ENV.fetch("BENCH_WORKERS", Etc.nprocessors))

# Before DummySuite.jobs, which asks each class for its runnable_methods, which srands with the
# seed. Nothing has set one because Minitest.run is not involved here.
Minitest::Ractor.seed! Integer(ENV.fetch("BENCH_SEED", 42))
jobs = DummySuite.jobs

modes = {
  "serial" => -> { Serially.new },
  "threads (#{workers})" => -> { Minitest::Parallel::Executor.new workers },
  "ractors (#{workers})" => -> { Minitest::Ractor::Executor.new workers }
}

puts "#{jobs.size} tests, fib(#{DummySuite::WORK}) each, #{DummySuite::SLEEPERS} that sleep"
puts "#{Etc.nprocessors} processors, Ruby #{RUBY_VERSION}, Minitest #{Minitest::VERSION}"

puts "\nchecking every mode agrees before timing anything"
modes.each do |name, build|
  tally = drive build.call, jobs

  unless tally.problems.empty?
    warn "\n#{name}: #{tally.problems.size} of #{jobs.size} tests did not pass."
    warn "Not timing anything — a mode that fails fast would look like a speed-up."
    tally.problems.first(5).each { |problem| warn "  #{problem}" }
    exit 1
  end

  puts format("  %<mode>-14s %<passed>d of %<total>d passed",
              mode: name, passed: tally.passes, total: jobs.size)
end

puts
Benchmark.ips do |bench|
  bench.config time: Integer(ENV.fetch("BENCH_TIME", 8)), warmup: 2

  modes.each do |name, build|
    bench.report(name) { drive build.call, jobs }
  end

  bench.compare!
end
