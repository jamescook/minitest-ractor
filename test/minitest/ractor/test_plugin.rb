# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/plugin"

class TestPlugin < Minitest::Test
  Plugin = Minitest::Ractor::Plugin

  # This suite is itself running under a parallel executor. Every test here pokes at the global
  # one, so it is put back afterwards without exception.
  def setup
    @executor_before = Minitest.parallel_executor
  end

  def teardown
    Minitest.parallel_executor = @executor_before
  end

  # THE GUARANTEE THE WHOLE OPT-IN DESIGN EXISTS FOR. Loading this gem must change nothing on its
  # own: the flag and the env var are the only two things that may switch a suite to Ractors.
  #
  # The people it would surprise are the ones who asked for the gem by name, which is reason
  # enough: wanting Ractors in CI is not the same as wanting them on every run.
  def test_nothing_happens_without_being_asked
    Minitest.parallel_executor = nil

    assert_equal :not_asked, Plugin.install_at_load({})
    assert_nil Minitest.parallel_executor
  end

  def test_the_env_var_installs_the_pool_at_load_time
    Minitest.parallel_executor = nil

    assert_equal :installed, Plugin.install_at_load({ "MT_RACTOR" => "1" })
    assert_kind_of Minitest::Ractor::Executor, Minitest.parallel_executor
  end

  # Somebody who installed their own executor has said something about how they want their tests
  # run. An env var picked up by a gem they may not remember installing does not outrank that.
  def test_an_executor_somebody_else_installed_is_left_alone
    theirs = Minitest::Parallel::Executor.new 2
    Minitest.parallel_executor = theirs

    assert_equal :left_alone, Plugin.install_at_load({ "MT_RACTOR" => "1" })
    assert_same theirs, Minitest.parallel_executor
  end

  # MT_RACTOR=0 is somebody turning it off. Treating that as "the variable is set, therefore
  # yes" is the kind of thing people lose an afternoon to.
  def test_switching_it_off_is_not_switching_it_on
    %w[0 false FALSE no].push("", "  ").each do |value|
      refute Plugin.opted_in?({ "MT_RACTOR" => value }), "#{value.inspect} should mean no"
    end

    %w[1 true yes on anything].each do |value|
      assert Plugin.opted_in?({ "MT_RACTOR" => value }), "#{value.inspect} should mean yes"
    end
  end

  def test_the_pool_size_can_be_set_and_otherwise_follows_the_machine
    assert_equal 3, Plugin.workers({ "MT_RACTOR_WORKERS" => "3" })
    assert_equal Minitest::Ractor::Executor.default_size, Plugin.workers({})
    assert_equal Minitest::Ractor::Executor.default_size, Plugin.workers({ "MT_RACTOR_WORKERS" => "0" })
  end

  # The hole, and the reason this gem has an env var at all. Under MT_CPU=1 minitest builds no
  # executor, so parallelize_me! already did nothing by the time a flag can be read. Swapping the
  # executor now changes nothing, because nothing is left that would ask for it.
  def test_asking_by_flag_alone_with_threads_disabled_refuses_to_run
    Minitest.parallel_executor = nil

    error = assert_raises Minitest::Ractor::ProofNotAttempted do
      Plugin.init({ ractor: true }, { "MT_CPU" => "1" })
    end

    assert_match(/MT_RACTOR=1/, error.message, "the error has to name the fix")
    assert_match(/stopped the run|without a proof/, error.message)
  end

  # ...and the same situation is fine once the env var got in first, because then the pool was
  # already there when parallelize_me! looked.
  def test_disabled_threads_are_fine_when_the_env_var_got_there_first
    Minitest.parallel_executor = nil
    Plugin.install_at_load({ "MT_RACTOR" => "1" })

    assert_equal :installed, Plugin.init({ ractor: true }, { "MT_CPU" => "1", "MT_RACTOR" => "1" },
                                         reporter: nil, runnables: [parallel_runnable])
  end

  def test_the_flag_installs_the_pool_and_a_reporter
    Minitest.parallel_executor = nil
    reporter = Minitest::CompositeReporter.new

    assert_equal :installed, Plugin.init({ ractor: true, io: StringIO.new }, {}, reporter:,
                                                                                 runnables: [parallel_runnable])
    assert_kind_of Minitest::Ractor::Executor, Minitest.parallel_executor
    assert reporter.reporters.any?(Minitest::Ractor::Reporter)
  end

  # --no-ractor has to beat MT_RACTOR, or somebody with the variable exported has no way to turn
  # this off for one run — which is the whole reason the switch exists.
  def test_declining_on_the_command_line_beats_the_environment
    Minitest.parallel_executor = nil
    Plugin.install_at_load({ "MT_RACTOR" => "1" })

    assert_equal :declined, Plugin.init({ ractor: false }, { "MT_RACTOR" => "1" }, reporter: nil)
  end

  # ...and declining has to actively UNDO the load-time install, because by now parallelize_me!
  # has already run and the classes are parallel. Leaving our pool in place would run everything
  # in Ractors anyway; leaving nothing in place would dispatch into nil.
  def test_declining_puts_back_the_executor_minitest_would_have_had
    Minitest.parallel_executor = nil
    Plugin.install_at_load({ "MT_RACTOR" => "1" })

    Plugin.init({ ractor: false }, { "MT_RACTOR" => "1" }, reporter: nil)

    refute_predicate Plugin, :ractor_pool_installed?
    assert_kind_of Minitest::Parallel::Executor, Minitest.parallel_executor
  end

  def test_declining_when_nothing_was_installed_leaves_it_alone
    Minitest.parallel_executor = nil

    assert_equal :declined, Plugin.init({ ractor: false }, {}, reporter: nil)
    assert_nil Minitest.parallel_executor
  end

  # Stands in for a test class. Only the two things pre-flight asks about.
  Runnable = Struct.new(:run_order, :runnable_methods)

  def parallel_runnable(tests: %w[test_a])
    Runnable.new(:parallel, tests)
  end

  def serial_runnable(tests: %w[test_a])
    Runnable.new(:random, tests)
  end

  # PRE-FLIGHT. By init_plugins every test class is loaded and its run_order is settled, so
  # whether anything can reach a Ractor is knowable in milliseconds rather than after a
  # ten-minute suite that proves nothing.
  def test_preflight_counts_the_tests_that_can_reach_a_ractor
    assert_equal 2, Plugin.preflight!([parallel_runnable(tests: %w[test_a test_b]),
                                       serial_runnable], {})
  end

  # A suite of mixed parallel and serial classes is legitimate. A partial number is the truth
  # about what was proved, not a warning.
  def test_preflight_is_happy_with_a_partly_parallel_suite
    assert_equal 1, Plugin.preflight!([parallel_runnable, serial_runnable, serial_runnable], {})
  end

  def test_preflight_refuses_a_suite_where_nothing_is_parallel
    error = assert_raises Minitest::Ractor::ProofNotAttempted do
      Plugin.preflight!([serial_runnable, serial_runnable], {})
    end

    assert_match(/parallelize_me!/, error.message, "it has to name the likely reason")
  end

  # The check does not care WHY nothing is parallel — enumerating the causes is a losing game —
  # but it should still point at the likeliest one, and MT_CPU=1 is a different fix.
  def test_preflight_blames_mt_cpu_when_that_is_the_likely_reason
    error = assert_raises Minitest::Ractor::ProofNotAttempted do
      Plugin.preflight!([serial_runnable], { "MT_CPU" => "1" })
    end

    assert_match(/MT_RACTOR=1/, error.message)
  end

  # A class with no tests in it cannot reach a Ractor however it is marked.
  def test_preflight_ignores_parallel_classes_with_no_tests
    assert_raises Minitest::Ractor::ProofNotAttempted do
      Plugin.preflight!([parallel_runnable(tests: [])], {})
    end
  end

  def test_init_runs_preflight_and_refuses_a_suite_that_cannot_prove_anything
    Minitest.parallel_executor = nil

    assert_raises Minitest::Ractor::ProofNotAttempted do
      Plugin.init({ ractor: true }, {}, reporter: nil, runnables: [serial_runnable])
    end
  end

  def test_init_does_nothing_when_nobody_asked
    Minitest.parallel_executor = nil
    reporter = Minitest::CompositeReporter.new

    assert_equal :not_asked, Plugin.init({}, {}, reporter:)
    assert_nil Minitest.parallel_executor
    assert_empty reporter.reporters
  end
end
