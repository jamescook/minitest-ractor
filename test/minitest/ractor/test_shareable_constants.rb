# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/shareable_constants"
require "fixtures/crossing_test"

class TestShareableConstants < Minitest::Test
  Patch = Minitest::Ractor::ShareableConstants

  def setup
    Patch.apply!
  end

  def test_every_named_constant_is_shareable_once_applied
    Patch::CONSTANTS.each do |owner_name, names|
      owner = Object.const_get(owner_name)

      names.each do |name|
        next unless owner.const_defined?(name, false)

        assert Ractor.shareable?(owner.const_get(name, false)), "#{owner_name}::#{name} is not shareable"
      end
    end
  end

  # The one that hid every other cause. It is read while BUILDING a failure message, so it
  # fires only after something has already gone wrong and replaces the real error with its own.
  def test_the_backtrace_filter_is_shareable
    assert Ractor.shareable?(Minitest.backtrace_filter)
  end

  def test_a_worker_can_filter_a_backtrace
    filtered = Ractor.new { Minitest.filter_backtrace(["x.rb:1:in 'a'"]) }.value

    assert_equal ["x.rb:1:in 'a'"], filtered
  end

  # Named so the reason survives: these are unshareable too and must stay that way.
  def test_the_executor_and_the_io_lock_are_left_alone
    refute_includes Patch.patched.keys, "Minitest.parallel_executor"
    refute_includes Patch.patched.keys, "Minitest::Test.io_lock"
  end

  def test_applying_twice_is_harmless
    Patch.apply!
    Patch.apply!

    assert_predicate Patch, :applied?
  end

  def test_the_constants_keep_their_values
    assert_includes Minitest::Test::PASSTHROUGH_EXCEPTIONS, NoMemoryError
    assert_includes Minitest::Test::SETUP_METHODS, "setup"
    assert_includes Minitest::Test::TEARDOWN_METHODS, "teardown"
  end

  def test_patched_accounts_for_every_name_it_was_given
    expected = Patch::CONSTANTS.flat_map { |owner, names| names.map { |n| "#{owner}::#{n}" } }

    assert_equal (expected + Patch::IVARS).sort, Patch.patched.keys.sort

    Patch.patched.each_value do |what|
      assert_includes %i[made_shareable left_alone absent], what
    end
  end

  def test_applying_again_leaves_everything_alone
    Patch.apply!

    refute_includes Patch.patched.values, :made_shareable
  end

  # Spec is only loaded if somebody requires it, so a name under it must be skipped rather than
  # raise — unlike the three under Minitest::Test, whose absence means an unpatchable Minitest.
  def test_an_absent_optional_constant_is_recorded_not_raised
    assert_includes Patch.patched.values, :left_alone
    refute_empty Patch.patched
  end

  def test_the_record_is_itself_shareable
    # A tool that demands the code under test hold no shared mutable state should hold none.
    assert Ractor.shareable?(Patch.patched)
  end

  # Being shareable is what makes this readable from a worker at all. A module ivar holding an
  # unshareable value raises from a non-main Ractor; holding a shareable one does not.
  def test_a_worker_can_read_the_record
    from_worker = Ractor.new { Minitest::Ractor::ShareableConstants.patched }.value

    assert_equal Patch.patched, from_worker
  end

  def test_report_names_the_constants_and_the_minitest_it_patched
    report = Patch.report

    assert_includes report, "Minitest #{Minitest::VERSION}"
    assert_includes report, "Minitest::Test::SETUP_METHODS"
    assert_includes report, "Minitest.backtrace_filter"
  end

  def test_a_result_crosses_home_from_a_ractor
    %w[test_passes test_fails test_errors test_skips].each do |name|
      result = Ractor.new(CrossingFixture, name) { |klass, m| klass.new(m).run }.value

      assert_equal name, result.name
      refute_nil result.result_code
    end
  end

  def test_pass_failure_error_and_skip_are_told_apart_across_the_boundary
    codes = %w[test_passes test_fails test_errors test_skips].to_h do |name|
      result = Ractor.new(CrossingFixture, name) { |klass, m| klass.new(m).run }.value
      [name, result.result_code]
    end

    assert_equal({ "test_passes" => ".", "test_fails" => "F",
                   "test_errors" => "E", "test_skips" => "S" }, codes)
  end

  def test_a_failure_arrives_with_its_message_intact
    result = Ractor.new(CrossingFixture, "test_fails") { |klass, m| klass.new(m).run }.value

    assert_equal 1, result.failures.size
    assert_kind_of Minitest::Assertion, result.failures.first
    assert_match(/Expected: 5/, result.failures.first.message)
  end
end
