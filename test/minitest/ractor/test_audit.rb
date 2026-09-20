# frozen_string_literal: true

require "test_helper"
require "open3"

# The audit runner, in subprocesses.
#
# Its whole difficulty is a hook installed at require time, so it cannot be tested honestly in a
# process where that require has already happened. These shell out to the real executable and
# read what a user would see.
class TestAudit < Minitest::Test
  # A stand-in for somebody else's project: requires minitest/autorun, calls parallelize_me!
  # nowhere, has never heard of this gem. Its files are named *_test.rb rather than test_*.rb so
  # that this repository's own runner does not glob them up and run its deliberately unsafe
  # class as though it were one of ours.
  SUITE = File.expand_path "../../fixtures/sample_suite", __dir__
  EXE   = File.expand_path "../../../exe/minitest-ractor", __dir__
  LIB   = File.expand_path "../../../lib", __dir__

  BASE_ENV = { "MT_CPU" => nil, "MT_RACTOR" => nil, "MT_RACTOR_WORKERS" => nil }.freeze

  def audit(*)
    Open3.capture2e(BASE_ENV, RbConfig.ruby, "-W0", "-I#{LIB}", EXE, *)
  end

  # THE PROBLEM THIS EXISTS TO SOLVE. Every target file requires minitest/autorun, which installs
  # an at_exit hook that runs the whole suite. A harness that loads those files and then runs
  # them itself gets two runs: its own, then minitest's afterwards, the normal way, printing its
  # own summary last and burying the real output.
  def test_the_target_suite_is_not_run_a_second_time_by_autorun
    output, = audit SUITE

    refute_match(/\d+ runs, \d+ assertions/, output,
                 "that is minitest's own summary, which means autorun ran the suite again")
    assert_equal 1, output.scan("minitest-ractor:").size, "exactly one report"
  end

  def test_it_finds_what_is_not_ractor_safe_in_an_unprepared_suite
    output, = audit SUITE

    assert_includes output, "ivar_write"
    assert_includes output, "Catalogue.index"
    assert_includes output, "CatalogueTest#test_reads_the_memo"
  end

  # An unprepared suite calls parallelize_me! nowhere, so every test would run in the main Ractor
  # and the audit would report a confident nothing. The runner has to arrange coverage itself.
  def test_every_test_in_an_unprepared_suite_still_reaches_a_ractor
    output, = audit SUITE

    assert_includes output, "4 of 4 tests ran in Ractors"
  end

  def test_it_accepts_individual_files_as_well_as_a_directory
    output, = audit File.join(SUITE, "arithmetic_test.rb")

    assert_includes output, "2 of 2 tests ran in Ractors"
    assert_includes output, "no findings"
  end

  # A finding is not an error in the runner. The audit did its job; the suite has work to do.
  def test_it_exits_non_zero_when_it_finds_something
    _, status = audit SUITE

    refute_predicate status, :success?
  end

  def test_it_exits_zero_on_a_clean_suite
    _, status = audit File.join(SUITE, "arithmetic_test.rb")

    assert_predicate status, :success?
  end

  def test_it_says_so_rather_than_crashing_when_given_nothing_to_run
    output, status = audit File.join(SUITE, "no_such_file.rb")

    refute_predicate status, :success?
    assert_match(/no test files|not found|nothing/i, output)
  end
end
