# frozen_string_literal: true

require "minitest"

# A specimen of the pattern this tool exists to find, and the commonest one in real suites:
# something expensive memoised on the test class and shared between tests.
#
# It fails on the WRITE, not the read, and the difference is the whole point. A worker may read
# a class's instance variable perfectly well — reading this one gives nil, which is shareable and
# allowed — but it may not write one at all. So Ruby's complaint here is "can not set instance
# variables of classes/modules by non-main Ractors", which names neither the class nor the
# variable, and the only thing identifying this cause is the line it happened on.
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
