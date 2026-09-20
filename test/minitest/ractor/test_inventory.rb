# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/inventory"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/unsafe_test"
require "fixtures/masked_test"

class TestInventory < Minitest::Test
  Inventory = Minitest::Ractor::Inventory

  def setup
    @reporter = RecordingReporter.new
    @executor = Minitest::Ractor::Executor.new(2)
  end

  def results_for(klass, names)
    already = @reporter.recorded.size

    @executor.start
    names.each { |name| @executor << [klass, name, @reporter] }
    @executor.shutdown

    @reporter.recorded.drop(already).map(&:result)
  end

  def report_for(...)
    Inventory.from(results_for(...)).to_s
  end

  # The requirement, stated in the brief: one cause reached by many tests is ONE entry with a
  # count beside it. A report that prints the same refusal once per test is the wall of noise
  # this replaces.
  def test_one_cause_reached_by_many_tests_is_reported_once
    report = report_for UnsafeFixture, %w[test_reads_a_class_level_ivar test_also_reads_it]

    # Keyed on the method rather than a line number, which moves whenever the fixture's comment
    # is edited and says nothing about the behaviour under test.
    assert_equal 1, report.scan("UnsafeFixture.expensive_thing").size,
                 "the cause belongs in the report once"
    assert_match(/2 findings/, report)
    assert_match(/1 cause\b/, report)
  end

  # Both tests are still named, because "one entry" must not mean "the other test vanished".
  def test_every_test_that_reached_the_cause_is_still_named_under_it
    report = report_for UnsafeFixture, %w[test_reads_a_class_level_ivar test_also_reads_it]

    assert_includes report, "UnsafeFixture#test_reads_a_class_level_ivar"
    assert_includes report, "UnsafeFixture#test_also_reads_it"
  end

  # What somebody greps for is the name Ruby gave, not the kind of mistake it was.
  def test_a_named_cause_leads_with_the_thing_it_names
    report = report_for MaskedFixture, %w[test_reads_it_plainly]

    assert_includes report, "ivar_read: @memo from MaskedFixture"
  end

  # The invariant that makes the rest of the report worth reading. An ordinary failure is
  # counted, said out loud, and kept out of the inventory.
  def test_ordinary_failures_are_counted_and_never_listed
    inventory = Inventory.from results_for(CrossingFixture, %w[test_fails test_errors])

    assert_predicate inventory, :empty?
    assert_equal 2, inventory.ordinary_failures

    report = inventory.to_s

    assert_includes report, "2 ordinary failures"
    refute_includes report, "CrossingFixture#test_fails"
  end

  def test_a_skip_is_neither_a_finding_nor_an_ordinary_failure
    inventory = Inventory.from results_for(CrossingFixture, %w[test_skips test_passes])

    assert_predicate inventory, :empty?
    assert_equal 0, inventory.ordinary_failures
  end

  # Largest first, because the largest is the one worth somebody's afternoon.
  def test_the_biggest_cause_comes_first
    results = results_for(MaskedFixture, %w[test_writes_it_plainly]) +
              results_for(UnsafeFixture, %w[test_reads_a_class_level_ivar test_also_reads_it])

    report = Inventory.from(results).to_s

    assert_operator report.index("unsafe_test.rb"), :<, report.index("masked_test.rb"),
                    "the cause with two findings should be listed above the one with one"
  end

  # Causes past the limit lose their detail, never their existence. A report that silently drops
  # causes is worse than no report, because it looks complete.
  def test_causes_beyond_the_limit_keep_a_line_each
    results = results_for(UnsafeFixture, %w[test_reads_a_class_level_ivar]) +
              results_for(MaskedFixture, %w[test_reads_it_plainly test_writes_it_plainly])

    report = Inventory.from(results, limit: 1).to_s

    assert_match(/2 further causes, in brief/, report)
    assert_includes report, "ivar_read: @memo from MaskedFixture"
    assert_includes report, "MaskedFixture.memoise", "an unnamed cause still needs its location"
  end

  # A green run is the product, and the limit on what it proves is the part people drop when
  # they repeat it. So the report says it rather than leaving it to the README.
  def test_a_run_with_no_findings_states_what_it_does_and_does_not_prove
    report = report_for CrossingFixture, %w[test_passes]

    assert_includes report, "no findings"
    assert_includes report, "none of them reached shared mutable state"
    assert_includes report, "THESE TESTS REACHED"
  end

  # THE CARDINAL SIN. A suite whose classes never called parallelize_me! runs entirely in the
  # main Ractor, and every test passes for the same reason it always did. Reporting "no findings"
  # there claims a proof that was never attempted, which is indistinguishable from success and
  # the worst thing this tool can do.
  #
  # The executor stamps every result with the worker that ran it, so an unstamped result is one
  # that never left home and the report can tell.
  def test_a_run_that_never_reached_a_worker_does_not_claim_a_proof
    never_left_home = %w[test_passes].map { |name| CrossingFixture.new(name).run }

    report = Inventory.from(never_left_home).to_s

    refute_includes report, "none of them reached shared mutable state",
                    "this run proved nothing and must not say otherwise"
    assert_includes report, "parallelize_me!", "and it has to say what is missing"
  end

  def test_it_counts_how_many_tests_actually_reached_a_worker
    through_the_pool = results_for CrossingFixture, %w[test_passes]
    at_home          = [CrossingFixture.new("test_passes").run]

    assert_equal 1, Inventory.from(through_the_pool).reached_workers
    assert_equal 0, Inventory.from(at_home).reached_workers
  end
end
