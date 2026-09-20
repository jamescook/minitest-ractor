# frozen_string_literal: true

require "test_helper"
require "minitest/ractor"
require "fixtures/crossing_test"

class TestSeed < Minitest::Test
  # This suite has a seed of its own, set by Minitest.run. Every test here clears it.
  def setup
    @seed_before = Minitest.seed
  end

  def teardown
    Minitest.seed = @seed_before
  end

  # The trap, and it is worth pinning down because the error it produces names nothing useful:
  # "no implicit conversion of nil into Integer" from deep inside Kernel#srand.
  #
  # Minitest::Test.runnable_methods calls `srand Minitest.seed`, and the seed is nil until
  # something sets it. Minitest.run sets it before init_plugins, so the plugin path never sees
  # this — it is anything enumerating tests WITHOUT going through Minitest.run that does.
  def test_enumerating_tests_without_a_seed_is_what_breaks
    Minitest.seed = nil

    assert_raises TypeError do
      CrossingFixture.runnable_methods
    end
  end

  def test_seeding_first_makes_enumeration_work
    Minitest.seed = nil
    Minitest::Ractor.seed!

    refute_empty CrossingFixture.runnable_methods
  end

  def test_it_leaves_a_seed_somebody_already_chose_alone
    Minitest.seed = 1234

    assert_equal 1234, Minitest::Ractor.seed!
    assert_equal 1234, Minitest.seed
  end

  def test_an_explicit_seed_wins
    Minitest.seed = 1234

    assert_equal 99, Minitest::Ractor.seed!(99)
    assert_equal 99, Minitest.seed
  end

  # SEED is the variable minitest itself reads, so a run that is being reproduced from one
  # should reproduce here too rather than quietly using our own default.
  def test_it_honours_the_seed_environment_variable
    Minitest.seed = nil

    assert_equal 7, Minitest::Ractor.seed!(nil, { "SEED" => "7" })
  end

  def test_it_falls_back_to_something_usable
    Minitest.seed = nil

    assert_kind_of Integer, Minitest::Ractor.seed!(nil, {})
  end
end
