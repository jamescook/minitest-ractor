# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/unsafe_test"
require "fixtures/masked_test"

class TestExecutor < Minitest::Test
  def setup
    @reporter = RecordingReporter.new
    @executor = Minitest::Ractor::Executor.new(3)
  end

  def run_jobs(names, klass: CrossingFixture)
    @executor.start
    names.each { |name| @executor << [klass, name, @reporter] }
    @executor.shutdown
  end

  def test_every_job_is_recorded_exactly_once
    names = %w[test_passes test_fails test_errors test_skips]

    run_jobs names

    assert_equal names.sort, @reporter.names.sort
  end

  # A guard, not a discovery: the design already keeps the reporter at home. It is here so that
  # sending the reporter into a worker — which looks like an obvious simplification — fails.
  def test_the_reporter_is_never_touched_from_a_worker
    run_jobs %w[test_passes test_fails test_errors test_skips]

    touched = (@reporter.recorded + @reporter.prerecorded).map(&:ractor).uniq

    assert_equal [::Ractor.main], touched
  end

  def test_pass_failure_error_and_skip_are_told_apart
    run_jobs %w[test_passes test_fails test_errors test_skips]

    codes = @reporter.recorded.to_h { |call| [call.name, call.result.result_code] }

    assert_equal({ "test_passes" => ".", "test_fails" => "F",
                   "test_errors" => "E", "test_skips" => "S" }, codes)
  end

  def test_a_failure_keeps_its_message
    run_jobs %w[test_fails]

    failure = @reporter.recorded.first.result.failures.first

    assert_kind_of Minitest::Assertion, failure
    assert_match(/Expected: 5/, failure.message)
  end

  def test_shutdown_leaves_no_workers_behind
    baseline = ::Ractor.count

    run_jobs %w[test_passes test_fails test_errors test_skips]

    assert_equal baseline, ::Ractor.count
  end

  # Four jobs over three workers: the first three go out before any can come back, because a
  # worker only rejoins the idle list when its result is collected. So the work genuinely lands
  # on three Ractors, which is the difference between this and a slow serial runner.
  def test_work_is_spread_over_the_whole_pool
    run_jobs %w[test_passes test_fails test_errors test_skips]

    workers = @reporter.workers

    refute_includes workers, nil, "every result should be stamped with the worker that ran it"
    assert_equal 3, workers.uniq.size
  end

  # The other half of the test above. Without this, "three distinct workers" could be true by
  # accident of how the stamp is written rather than because the work really went three ways.
  def test_a_pool_of_one_runs_everything_on_one_worker
    @executor = Minitest::Ractor::Executor.new(1)

    run_jobs %w[test_passes test_fails test_errors test_skips]

    assert_equal [0], @reporter.workers.uniq
    assert_equal 4, @reporter.recorded.size
  end

  # The case the whole tool exists for. Shared mutable state must come back as a recorded
  # result naming what went wrong — not take the pool down, and not vanish.
  def test_shared_mutable_state_comes_back_as_a_recorded_error
    run_jobs %w[test_reads_a_class_level_ivar test_also_reads_it], klass: UnsafeFixture

    assert_equal 2, @reporter.recorded.size

    @reporter.recorded.each do |call|
      assert_equal "E", call.result.result_code
      assert_match(/IsolationError/, call.result.failures.first.message)
    end
  end

  # A Ractor::Port empties the backtrace of an exception nested in an object graph — the same
  # failure keeps its frames across Ractor#value and loses them across a Port. The executor has
  # no choice about the Port, so the frames have to be lifted out inside the worker and put back
  # on arrival. An inventory that cannot name a file is most of the way to useless.
  def test_a_failure_arrives_with_a_backtrace_naming_the_line
    run_jobs %w[test_reads_a_class_level_ivar], klass: UnsafeFixture

    failure = @reporter.recorded.first.result.failures.first

    refute_empty Array(failure.backtrace), "a failure with no backtrace cannot be located"
    assert_includes failure.backtrace.join("\n"), "unsafe_test.rb"
  end

  # Asserted on the whole backtrace rather than its first frame: an assertion failure is raised
  # inside Minitest::Assertions#assert, so the test's own file is several frames down. Minitest
  # normally trims those with backtrace_filter, which does not survive a worker either.
  def test_an_ordinary_assertion_failure_also_keeps_its_backtrace
    run_jobs %w[test_fails]

    failure = @reporter.recorded.first.result.failures.first

    refute_empty Array(failure.backtrace)
    assert_includes failure.backtrace.join("\n"), "crossing_test.rb"
  end

  # Carrying the failure's own backtrace is not enough when the failure is a mask. Here the
  # failure is the Minitest::Assertion raised by assert_raises and its frames point at
  # assert_raises; the isolation error is one link down the cause chain, and the Port empties
  # its backtrace exactly the same way. Without this the classifier can name the cause and still
  # not say where it happened.
  def test_a_masked_isolation_error_arrives_with_its_own_backtrace
    run_jobs %w[test_expects_an_argument_error], klass: MaskedFixture

    failure = @reporter.recorded.first.result.failures.first
    cause   = failure.cause

    assert_kind_of ::Ractor::IsolationError, cause, "the cause chain should survive the Port"
    refute_empty Array(cause.backtrace), "a cause with no backtrace cannot be located"
    assert_includes cause.backtrace.join("\n"), "masked_test.rb"
  end

  def test_the_pool_survives_shared_mutable_state_and_keeps_working
    @executor.start
    @executor << [UnsafeFixture, "test_reads_a_class_level_ivar", @reporter]
    @executor << [CrossingFixture, "test_passes", @reporter]
    @executor.shutdown

    codes = @reporter.recorded.to_h { |call| [call.name, call.result.result_code] }

    assert_equal({ "test_reads_a_class_level_ivar" => "E", "test_passes" => "." }, codes)
  end
end
