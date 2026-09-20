# frozen_string_literal: true

# The other half of the target suite: tests that are already fine.
#
# An audit that only ever reports problems would say nothing about how much of a suite is
# already Ractor-safe, and the coverage line depends on these passing in a worker like any
# other.

require "minitest/autorun"

class ArithmeticTest < Minitest::Test
  def test_adds
    assert_equal 4, 2 + 2
  end

  def test_multiplies
    assert_equal 6, 2 * 3
  end
end
