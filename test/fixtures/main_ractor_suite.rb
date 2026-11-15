# frozen_string_literal: true

# A suite in which no test reaches a Ractor, for the post-flight tests. MAIN_RACTOR_SUITE picks
# the reason:
#
#   opted_out          every class said runs_on_the_main_ractor!, and every test passes
#   opted_out_failing  the same, with one test that fails
#   forgot             the same classes without the opt-outs, staying on the main Ractor by mistake
#   mixed              the opted-out classes plus one class that stays home by mistake
#
# Staying home by mistake has to get past pre-flight to reach the reporter at all, so those
# classes claim a parallel run order without calling parallelize_me!. Pre-flight trusts the run
# order, minitest never hands the class to the executor, and every test runs in the main Ractor
# unstamped. That is the kind of slip pre-flight cannot see and post-flight exists to catch.

require "minitest/autorun"
require "minitest/ractor"

MODE = ENV.fetch "MAIN_RACTOR_SUITE", "opted_out"

def stays_home(klass, on_purpose:)
  if on_purpose
    klass.parallelize_me!
    klass.runs_on_the_main_ractor!
  else
    klass.define_singleton_method(:run_order) { :parallel }
  end
end

class RegistersAPlugin < Minitest::Test
  stays_home self, on_purpose: MODE != "forgot"

  def test_registers
    assert_equal ::Ractor.main, ::Ractor.current
  end

  def test_registers_again
    assert_equal ::Ractor.main, ::Ractor.current
  end
end

class RegistersAFont < Minitest::Test
  stays_home self, on_purpose: MODE != "forgot"

  def test_registers
    assert_equal ::Ractor.main, ::Ractor.current
  end

  if MODE == "opted_out_failing"
    def test_fails
      flunk "a real failure"
    end
  end
end

if MODE == "mixed"
  class ForgotToParallelise < Minitest::Test
    stays_home self, on_purpose: false

    def test_stays_home
      assert_equal ::Ractor.main, ::Ractor.current
    end
  end
end
