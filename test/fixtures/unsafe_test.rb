# frozen_string_literal: true

require "minitest"

# A specimen of the pattern this tool exists to find, and the commonest one in real suites:
# something expensive memoised on the test class and shared between tests. A non-main Ractor
# may not read or write a class's instance variables, so this raises Ractor::IsolationError
# the moment a worker touches it.
#
# Not a bug to be fixed here. It is the input.
class UnsafeFixture < Minitest::Test
  def self.expensive_thing
    @expensive_thing ||= "built once, shared by everybody"
  end

  def test_reads_a_class_level_ivar
    assert_equal "built once, shared by everybody", self.class.expensive_thing
  end

  def test_also_reads_it
    refute_empty self.class.expensive_thing
  end
end

Minitest::Runnable.runnables.delete UnsafeFixture
