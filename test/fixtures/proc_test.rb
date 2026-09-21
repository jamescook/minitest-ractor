# frozen_string_literal: true

require "minitest"

# Tests built with define_method, which is how a suite writes the same test over a list of
# inputs. The method is a Proc, a Proc is not shareable, and a worker refuses to call it.
#
# THE POINT OF THE FIXTURE IS WHO DOES THE CALLING. Ruby reports this refusal at the line that
# INVOKED the method, never at the define_method — and for a test method the caller is minitest
# itself. So the frame lands in minitest's test.rb, which is a gem, and the finding used to be
# reported as somebody else's to fix. Running these through the executor is the only way to get
# that shape honestly, since it needs minitest to be the one calling.
#
# Two of them, on deliberately different lines, because the definition site is also the only
# thing that tells one such cause from another. Keyed on the frame they were a single cause for
# the whole suite.
class ProcFixture < Minitest::Test
  define_method(:test_built_with_a_proc) do
    assert_equal 4, 2 + 2
  end

  define_method(:test_built_with_another_proc) do
    assert_equal 4, 2 + 2
  end

  # An ordinary method, for contrast: same class, no Proc, runs in a worker perfectly well.
  def test_written_the_ordinary_way
    assert_equal 4, 2 + 2
  end
end
