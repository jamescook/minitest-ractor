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
    Patch::NAMES.each do |name|
      value = Minitest::Test.const_get(name)

      assert Ractor.shareable?(value), "Minitest::Test::#{name} is not shareable"
    end
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

  # The assertion that actually matters. Everything above is a proxy for this: can a test run
  # in a worker at all, and does what happened to it survive the trip back?
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
