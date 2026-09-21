# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/classifier"
require "minitest/ractor/executor"
require "recording_reporter"
require "fixtures/crossing_test"
require "fixtures/unsafe_test"
require "fixtures/masked_test"
require "fixtures/proc_test"

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

  # Minitest builds the "exception expected, not ..." message by embedding the class, message AND
  # backtrace of the exception it caught. So the outer Minitest::Assertion's own message CONTAINS
  # the refusal's wording, and matching against it succeeds while pointing at entirely the wrong
  # place — minitest's assertions.rb rather than the code at fault.
  #
  # Found against a real suite, where it split one cause into 2123 findings at the right line and
  # 298 at Minitest::Assertions#assert. The rule is to take the DEEPEST match in the chain, never
  # the first: an outer link can only ever be quoting an inner one.
  def test_a_masked_finding_is_located_in_the_code_at_fault_not_in_minitest
    finding = Classifier.classify results_for(MaskedFixture, %w[test_expects_an_argument_error]).first

    assert_includes finding.origin.to_s, "masked_test.rb"
    refute_includes finding.origin.to_s, "assertions.rb"
  end

  # The same mistake where it actually costs something. A named cause survives a wrong origin
  # because the name still groups it; an unnamed one has nothing else to be identified by, so a
  # wrong origin silently splits one problem into two entries in the inventory.
  def test_a_masked_write_and_a_plain_one_are_one_cause_not_two
    results = results_for MaskedFixture,
                          %w[test_expects_an_argument_error_from_a_write test_writes_it_plainly]

    inventory = Classifier.by_cause results

    assert_equal 1, inventory.size, "a mask must not split one unnamed cause in two"

    cause, found = inventory.first

    assert_equal :ivar_write, cause.kind
    refute_predicate cause, :named?
    assert_includes cause.origin.to_s, "masked_test.rb"
    assert_equal 2, found.size
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

  # Where the TEST is written, which is not always where the refusal happened.
  #
  # Ruby refuses a method built from an unshareable Proc before entering it, so a test defined
  # with define_method produces a backtrace with no frame of the author's on it at all — the top
  # frame is minitest's own dispatch line. Walking the backtrace cannot help, because there is
  # nothing to walk to. Minitest already computes the definition site though, so a finding
  # carries it and the report has something honest to point at.
  def test_a_finding_knows_where_its_test_is_written
    finding = Classifier.classify results_for(MaskedFixture, %w[test_reads_it_plainly]).first

    assert_includes finding.defined_at.to_s, "masked_test.rb"
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

  # A TEST BUILT WITH define_method, which is how a suite writes one test over a list of inputs.
  # Found by auditing a real suite, where every claim the report made about it was false.
  #
  # Ruby reports this refusal at the line that CALLED the method, and for a test method the
  # caller is minitest. So the frame is minitest/test.rb:91 — a gem — and the finding was tiered
  # as nobody's to fix, with a remedy saying the Proc belonged to a gem. It belongs to whoever
  # wrote the define_method, it is one line from fixed, and this gem's own README says how.
  #
  # Run through the executor rather than built, because minitest has to be the caller for the
  # refusal to have the shape that was getting it wrong.
  def test_a_test_built_with_define_method_is_located_at_the_define_method
    finding = Classifier.classify results_for(ProcFixture, %w[test_built_with_a_proc]).first

    refute_nil finding
    assert_equal :unshareable_proc, finding.cause.kind
    assert_includes finding.cause.origin, "fixtures/proc_test.rb"
    refute_includes finding.cause.origin, "minitest/test.rb", "the caller is not the offence"
  end

  def test_a_test_built_with_define_method_is_the_projects_to_fix
    cause = Classifier.classify(results_for(ProcFixture, %w[test_built_with_a_proc]).first).cause

    assert_equal :yours, cause.tier
    assert_includes cause.remedy, "Ractor.shareable_proc"
    refute_includes cause.remedy, "belongs to a gem"
  end

  # The other half, and the half that hides: keyed on the frame, EVERY define_method'd test in a
  # suite is one cause, because they all share minitest's line. Two files, two fixes, one entry.
  def test_two_define_method_calls_are_two_causes
    results = results_for ProcFixture, %w[test_built_with_a_proc test_built_with_another_proc]

    assert_equal 2, Classifier.by_cause(results).size,
                 "two definition sites are two things to fix"
  end

  def test_an_ordinary_method_in_the_same_class_is_not_a_finding
    results = results_for ProcFixture, %w[test_written_the_ordinary_way]

    assert_nil Classifier.classify(results.first)
  end
end
