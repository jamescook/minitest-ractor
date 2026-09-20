# frozen_string_literal: true

require "minitest"

# A test that kills the worker running it, and one that does not.
#
# Minitest re-raises PASSTHROUGH_EXCEPTIONS — NoMemoryError, SignalException, Interrupt,
# SystemExit — rather than recording them, so they escape #run entirely. In a thread pool that
# takes the process down. In a Ractor pool it used to take the worker down silently, and the
# main Ractor then waited forever for a result that could never arrive.
#
# The healthy test alongside it is the point: a pool that merely survives is not enough, it has
# to keep working.
class CasualtyFixture < Minitest::Test
  def test_kills_its_worker
    raise NoMemoryError, "pretending to run out of memory"
  end

  def test_is_perfectly_fine
    assert_equal 4, 2 + 2
  end
end

Minitest::Runnable.runnables.delete CasualtyFixture
