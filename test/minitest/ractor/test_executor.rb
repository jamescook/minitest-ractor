# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/unsafe_test"
require "fixtures/masked_test"
require "fixtures/casualty_test"
require "fixtures/unsendable_test"

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

  # Ractor.count is process-global and LAGS actual termination: a worker that has already handed
  # back its value can still be counted for a moment afterwards. Asserting it once made this test
  # fail roughly one run in twenty — more often as the rest of the suite grew Ractors of its own —
  # which in a tool whose product is trustworthy failure reporting is worse than in most places.
  #
  # Polling keeps what the test is actually for. A genuinely orphaned worker never terminates, so
  # it still fails, just after a wait instead of a coin toss.
  def settled_ractor_count(target, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    while ::Ractor.count > target && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.001
    end

    ::Ractor.count
  end

  def test_shutdown_leaves_no_workers_behind
    baseline = ::Ractor.count

    run_jobs %w[test_passes test_fails test_errors test_skips]

    assert_equal baseline, settled_ractor_count(baseline)
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

  # Minitest re-raises PASSTHROUGH_EXCEPTIONS instead of recording them, so they escape #run and
  # used to kill the worker outright. The result was never sent, and shutdown waited on
  # @outstanding for a result that could never arrive — the pool hung forever. Measured in
  # probes/worker_death.rb, which sat there until this was fixed.
  #
  # A hang is the worst failure available: CI kills it an hour later with no output, so nobody
  # even learns which test did it. An error recorded against the test that caused it is worth
  # far more.
  def test_an_exception_that_escapes_a_test_does_not_take_the_worker_with_it
    run_jobs %w[test_kills_its_worker], klass: CasualtyFixture

    result = @reporter.recorded.first.result

    assert_equal "E", result.result_code
    assert_match(/NoMemoryError|out of memory/, result.failures.first.message)
  end

  # Surviving is not enough — the pool has to keep working afterwards.
  def test_the_pool_keeps_working_after_a_test_kills_its_worker
    run_jobs %w[test_kills_its_worker test_is_perfectly_fine], klass: CasualtyFixture

    codes = @reporter.recorded.to_h { |call| [call.name, call.result.result_code] }

    assert_equal({ "test_kills_its_worker" => "E", "test_is_perfectly_fine" => "." }, codes)
  end

  # A Port copies what it sends, and a Proc cannot be copied — "allocator undefined for Proc".
  # Minitest documents metadata as plain marshal-able data, but that is a docstring rather than
  # a check, so a result can arrive at the send carrying something that will not go. The worker
  # used to die there with its job still outstanding, and shutdown waited forever.
  #
  # Only the foreign metadata is dropped, so the test's actual verdict still gets home. Measured
  # in probes/unsendable_failure.rb, which hung before this.
  def test_a_result_carrying_something_unsendable_still_arrives
    run_jobs %w[test_puts_a_proc_in_its_metadata], klass: UnsendableFixture

    result = @reporter.recorded.first.result

    assert_equal ".", result.result_code, "the verdict survives even though the metadata did not"
    refute_includes result.metadata.keys, :a_proc
  end

  # The worker stamp has to survive that retry, or a test whose metadata could not be sent would
  # look like one that never reached a Ractor — and enough of those turn a real run into a
  # "NO PROOF" report.
  def test_a_retried_result_still_says_which_worker_ran_it
    run_jobs %w[test_puts_a_proc_in_its_metadata], klass: UnsendableFixture

    refute_nil @reporter.recorded.first.result.metadata[:minitest_ractor_worker]
  end

  # Exceptions need no help from us: Ruby neuters one it cannot copy rather than refusing to
  # send it. Worth pinning down, because it is the reason this fix is about metadata and not
  # about failures, which is the opposite of what it looks like from the outside.
  def test_an_exception_ruby_cannot_copy_is_neutered_rather_than_lost
    run_jobs %w[test_raises_something_holding_a_proc], klass: UnsendableFixture

    result = @reporter.recorded.first.result

    assert_equal "E", result.result_code
    assert_match(/Neutered Exception.*CarriesAProc/, result.failures.first.message)
  end

  def test_the_pool_keeps_working_after_a_result_that_would_not_send
    run_jobs %w[test_puts_a_proc_in_its_metadata test_is_perfectly_fine], klass: UnsendableFixture

    assert_equal(%w[. .], @reporter.recorded.map { |call| call.result.result_code })
  end

  # The pre-flight and post-flight checks both assume shutdown is reached even when the executor
  # was handed nothing at all, so that assumption is worth a test of its own.
  def test_starting_and_shutting_down_with_no_work_is_harmless
    @executor.start

    assert_same @executor, @executor.shutdown
    assert_empty @reporter.recorded
  end

  # Ruby has no way to READ a signal handler: Signal.trap is the only accessor and it sets as
  # well as gets. So swap in something harmless, keep what fell out, and put it straight back.
  def current_int_handler
    handler = Signal.trap "INT", "DEFAULT"
    Signal.trap "INT", handler
    handler
  end

  # Ctrl+C has to reach the pool rather than minitest, which rescues Interrupt and then prints
  # every failure it had collected anyway. Borrowed, though, not taken: a process where the pool
  # has shut down is no longer the pool's to answer for.
  def test_the_pool_answers_ctrl_c_while_it_is_up_and_hands_it_back_afterwards
    before = current_int_handler

    @executor.start

    assert_kind_of Proc, current_int_handler, "the pool has to be what answers Ctrl+C"

    @executor.shutdown

    assert_equal before, current_int_handler
  end

  # Killing the process out from under somebody is a large thing for a library object to do, and
  # a program driving this directly may have its own idea of what Ctrl+C means.
  def test_a_caller_can_keep_ctrl_c_for_itself
    before   = current_int_handler
    executor = Minitest::Ractor::Executor.new(1, trap_interrupt: false)

    executor.start

    assert_equal before, current_int_handler
  ensure
    executor.shutdown
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
