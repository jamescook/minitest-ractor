# frozen_string_literal: true

require "minitest"

# A specimen suite, not a suite. Two of these deliberately do not pass: the point is to watch
# a pass, a failure, an error and a skip all survive the trip home from a worker.
#
# Defining a Minitest::Test subclass registers it as a runnable, so without the delete below
# our own suite would collect these and report two failures of its own. Excluding the file
# from the Rakefile is not enough — the test that uses this fixture has to require it.
class CrossingFixture < Minitest::Test
  def test_passes
    assert_equal 4, 2 + 2
  end

  def test_fails
    assert_equal 5, 2 + 2
  end

  def test_errors
    raise ArgumentError, "boom"
  end

  def test_skips
    skip "not today"
  end
end

Minitest::Runnable.runnables.delete CrossingFixture
