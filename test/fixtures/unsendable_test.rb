# frozen_string_literal: true

require "minitest"

# Results carrying things a Ractor::Port cannot copy.
#
# A Port COPIES what it sends, and not everything can be copied. The two halves behave quite
# differently, which is the reason this fixture has both:
#
#   AN EXCEPTION IS ALREADY SAFE. Ruby neuters one it cannot copy, so it arrives as a plain
#   RuntimeError reading "Neutered Exception <OriginalClass>: <message>" with its instance
#   variables dropped. Costs a little detail and nothing else.
#
#   METADATA IS NOT. Minitest documents it as "plain (read: marshal-able) data", but that is a
#   docstring rather than a check, and a Result holding a Proc there is an ordinary object graph
#   rather than an exception. Nothing neuters it: the send raises, and the worker used to die
#   with its job still outstanding while shutdown waited for a result that could never arrive.
class UnsendableFixture < Minitest::Test
  class CarriesAProc < StandardError
    def initialize(message = "an error holding a Proc")
      super
      @callback = -> { :never_called }
    end
  end

  def test_raises_something_holding_a_proc
    raise CarriesAProc
  end

  def test_puts_a_proc_in_its_metadata
    metadata[:a_proc] = -> { :never_called }

    assert_equal 4, 2 + 2
  end

  def test_is_perfectly_fine
    assert_equal 4, 2 + 2
  end
end

Minitest::Runnable.runnables.delete UnsendableFixture
