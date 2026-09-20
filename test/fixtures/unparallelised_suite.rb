# frozen_string_literal: true

# A suite that asks for Ractors and has no way of getting them, for the pre-flight tests.
#
# Nothing here calls parallelize_me!, so Minitest will run every test in the main Ractor however
# loudly the command line asks otherwise. Left unchecked this is the failure the whole gem is
# organised against: every test passes, the summary is green, and not one line of code was
# examined for isolation.

require "minitest/autorun"
require "minitest/ractor"

class UnparallelisedSuite < Minitest::Test
  def test_one
    $stdout.puts "RAN: test_one"

    assert_equal 4, 2 + 2
  end
end
