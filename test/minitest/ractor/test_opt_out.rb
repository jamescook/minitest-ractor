# frozen_string_literal: true

require "test_helper"
require "minitest/ractor"
require "minitest/ractor/executor"
require "minitest/ractor/inventory"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/opted_out_test"

class TestOptOut < Minitest::Test
  def setup
    @reporter = RecordingReporter.new
    @executor = Minitest::Ractor::Executor.new 2
  end

  def run_jobs(klass, names)
    already = @reporter.recorded.size

    @executor.start
    names.each { |name| @executor << [klass, name, @reporter] }
    @executor.shutdown

    @reporter.recorded.drop(already).map(&:result)
  end

  def test_a_class_says_nothing_until_it_says_it
    refute_predicate CrossingFixture, :runs_on_the_main_ractor?
    assert_predicate OptedOutFixture, :runs_on_the_main_ractor?
  end

  # A class ivar belongs to the class that set it. Marking a base class must not quietly opt out
  # everything beneath it, which would be a very easy way to prove nothing by accident.
  def test_it_is_not_inherited
    parent = Class.new(Minitest::Test) { runs_on_the_main_ractor! }
    child  = Class.new(parent)

    assert_predicate parent, :runs_on_the_main_ractor?
    refute_predicate child, :runs_on_the_main_ractor?
  end

  # The point of the whole thing: a test about global state runs, passes, and produces no
  # finding — because it never went near a worker.
  def test_an_opted_out_test_runs_in_the_main_ractor_and_passes
    results = run_jobs OptedOutFixture, %w[test_registers_something]

    assert_equal ".", results.first.result_code
    assert_nil results.first.metadata[:minitest_ractor_worker]
  end

  def test_an_opted_out_result_says_that_it_asked
    results = run_jobs OptedOutFixture, %w[test_registers_something]

    assert results.first.metadata[:minitest_ractor_opted_out]
  end

  # Without the opt-out this fixture is exactly the memoisation the tool exists to find, so the
  # absence of a finding here is the feature and not an oversight.
  def test_the_same_code_would_otherwise_be_a_finding
    opted = Minitest::Ractor::Inventory.from(run_jobs(OptedOutFixture, %w[test_registers_something]))

    assert_empty opted.findings
    assert_equal 1, opted.opted_out
  end

  def test_a_mixed_run_counts_all_three_groups
    results = run_jobs(OptedOutFixture, %w[test_registers_something test_registers_something_else]) +
              run_jobs(CrossingFixture, %w[test_passes])

    inventory = Minitest::Ractor::Inventory.from results

    assert_equal 1, inventory.reached_workers
    assert_equal 2, inventory.opted_out
    assert_equal 3, inventory.total
  end

  # THE REPORTING HALF, which matters as much as the mechanism. The scope of the proof depends on
  # this number, so it is stated rather than folded into a flat total.
  def test_the_report_says_how_many_asked_not_to
    results = run_jobs(OptedOutFixture, %w[test_registers_something test_registers_something_else]) +
              run_jobs(CrossingFixture, %w[test_passes])

    report = Minitest::Ractor::Inventory.from(results).to_s

    assert_includes report, "1 of 3 tests ran in Ractors"
    assert_includes report, "2 asked not to"
  end

  # An opt-out is not a test the pool failed to reach, and the report must not read as though a
  # deliberate narrowing were a shortfall.
  def test_asking_is_not_reported_as_an_unaccounted_test
    report = Minitest::Ractor::Inventory.from(run_jobs(OptedOutFixture,
                                                       %w[test_registers_something])).to_s

    refute_includes report, "without asking"
  end

  # A suite where EVERY class opted out proves nothing, and saying "add parallelize_me!" there
  # would send somebody to do the one thing that cannot help.
  def test_a_suite_that_entirely_opted_out_is_told_the_right_thing
    report = Minitest::Ractor::Inventory.from(run_jobs(OptedOutFixture,
                                                       %w[test_registers_something])).to_s

    assert_includes report, "NO PROOF"
    assert_includes report, "runs_on_the_main_ractor!"
    refute_includes report, "parallelize_me!", "that is not the fix when everything opted out"
  end
end
