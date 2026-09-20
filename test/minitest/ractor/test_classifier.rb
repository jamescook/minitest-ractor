# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/classifier"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/unsafe_test"
require "fixtures/masked_test"

class TestClassifier < Minitest::Test
  Classifier = Minitest::Ractor::Classifier

  def setup
    @reporter = RecordingReporter.new
    @executor = Minitest::Ractor::Executor.new(2)
  end

  # Real results off a real pool, not hand-built ones. What a Result looks like after crossing a
  # Port is the entire difficulty — backtraces emptied, causes intact — and a test that
  # constructs its own input would sail past every one of those.
  # Returns only what THIS call produced. The reporter keeps everything it has ever been given,
  # so a test that runs two fixtures would otherwise count the first batch twice.
  def results_for(klass, names)
    already = @reporter.recorded.size

    @executor.start
    names.each { |name| @executor << [klass, name, @reporter] }
    @executor.shutdown

    @reporter.recorded.drop(already).map(&:result)
  end

  # The one this bead exists for. Nothing on the surface of this result says Ractor: the failure
  # is a Minitest::Assertion reading "[ArgumentError] exception expected, not ...", which any
  # by-class check reads as somebody's test being wrong.
  def test_an_isolation_error_masked_by_assert_raises_is_still_a_finding
    result  = results_for(MaskedFixture, %w[test_expects_an_argument_error]).first
    finding = Classifier.classify result

    refute_nil finding, "a finding dressed as an ordinary failure must not be dropped"
    assert_equal :ivar_read, finding.cause.kind
    assert_equal "@memo from MaskedFixture", finding.cause.subject
  end

  # The other half of the invariant, and the half that would quietly inflate every number this
  # tool prints. A suite full of ordinary failures must produce an empty inventory.
  def test_an_ordinary_failure_is_not_a_finding
    results = results_for CrossingFixture, %w[test_fails test_errors]

    assert_equal 2, results.size, "the premise is that these really did fail"
    assert_empty Classifier.findings(results)
  end

  def test_a_passing_test_is_not_a_finding
    assert_nil Classifier.classify(results_for(CrossingFixture, %w[test_passes]).first)
  end

  def test_a_skipped_test_is_not_a_finding
    assert_nil Classifier.classify(results_for(CrossingFixture, %w[test_skips]).first)
  end

  # The commonest shape in the wild — memoising on the class — and the one Ruby says least
  # about. No variable, no owner, so the origin is all there is to group by, which makes
  # carrying the backtrace the difference between a usable finding and an anonymous one.
  def test_a_memoising_write_is_a_finding_located_by_its_backtrace
    finding = Classifier.classify results_for(UnsafeFixture, %w[test_reads_a_class_level_ivar]).first

    refute_nil finding
    assert_equal :ivar_write, finding.cause.kind
    refute_predicate finding.cause, :named?
    assert_includes finding.origin.to_s, "unsafe_test.rb"
  end

  def test_a_finding_names_the_test_it_came_from
    finding = Classifier.classify results_for(MaskedFixture, %w[test_reads_it_plainly]).first

    assert_equal "MaskedFixture#test_reads_it_plainly", finding.location
  end

  # The product, in one assertion. One unsafe ivar reached by two tests — one of them with the
  # refusal masked behind assert_raises, one plainly — is ONE thing to fix, and the inventory
  # says so once rather than twice.
  def test_a_masked_finding_and_a_plain_one_share_a_cause
    results = results_for MaskedFixture, %w[test_expects_an_argument_error test_reads_it_plainly]

    inventory = Classifier.by_cause results

    assert_equal 1, inventory.size, "these are two symptoms of a single unsafe ivar"

    cause, found = inventory.first

    assert_equal "@memo from MaskedFixture", cause.subject
    assert_equal %w[MaskedFixture#test_expects_an_argument_error MaskedFixture#test_reads_it_plainly],
                 found.map(&:location).sort
  end

  # Report by cause, not by test: the ordering has to put the biggest pile first, because that is
  # the one worth somebody's afternoon.
  def test_causes_come_back_commonest_first
    results = results_for(UnsafeFixture, %w[test_reads_a_class_level_ivar test_also_reads_it]) +
              results_for(MaskedFixture, %w[test_reads_it_plainly])

    counts = Classifier.by_cause(results).map { |_, found| found.size }

    assert_equal [2, 1], counts
  end
end
