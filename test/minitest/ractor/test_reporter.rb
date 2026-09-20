# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/reporter"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"

class TestReporter < Minitest::Test
  Reporter = Minitest::Ractor::Reporter

  def setup
    @io = StringIO.new
  end

  def through_the_pool(names)
    recorder = RecordingReporter.new
    executor = Minitest::Ractor::Executor.new 2

    executor.start
    names.each { |name| executor << [CrossingFixture, name, recorder] }
    executor.shutdown

    recorder.recorded.map(&:result)
  end

  def report_on(results)
    reporter = Reporter.new io: @io
    results.each { |result| reporter.record result }
    reporter
  end

  # POST-FLIGHT. Pre-flight can be fooled — an executor replaced after init, a class whose
  # run_order changed — so the last word belongs to what actually happened. Minitest ANDs
  # passed? across every reporter, so returning false here is what makes the run exit non-zero.
  def test_a_run_where_nothing_reached_a_worker_does_not_pass
    never_left_home = [CrossingFixture.new("test_passes").run]

    refute_predicate report_on(never_left_home), :passed?
  end

  def test_a_run_that_reached_workers_passes
    assert_predicate report_on(through_the_pool(%w[test_passes])), :passed?
  end

  # Failures are the tests' business and minitest already counts them. This reporter judges one
  # thing only: whether a proof was attempted. Counting failures here would count them twice.
  def test_it_does_not_fail_a_run_merely_because_tests_failed
    assert_predicate report_on(through_the_pool(%w[test_fails test_errors])), :passed?
  end

  def test_an_empty_run_is_not_a_failed_proof
    assert_predicate report_on([]), :passed?
  end

  def test_it_prints_the_inventory_when_the_run_ends
    report_on(through_the_pool(%w[test_passes])).report

    assert_includes @io.string, "minitest-ractor:"
  end
end
