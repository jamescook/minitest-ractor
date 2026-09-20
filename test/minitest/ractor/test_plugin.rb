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
  # On minitest 5 the stakes were higher — load_plugins required every installed gem's plugin
  # file on every run, so acting at load time would have hijacked suites that had never heard of
  # this one. Minitest 6 dropped that, so now it is only the people who asked for the gem by name
  # who would be surprised. Which is still reason enough.
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
    assert_match(/proved nothing|never attempted|Refusing/, error.message)
  end

  # ...and the same situation is fine once the env var got in first, because then the pool was
  # already there when parallelize_me! looked.
  def test_disabled_threads_are_fine_when_the_env_var_got_there_first
    Minitest.parallel_executor = nil
    Plugin.install_at_load({ "MT_RACTOR" => "1" })

    assert_equal :installed, Plugin.init({ ractor: true }, { "MT_CPU" => "1", "MT_RACTOR" => "1" },
                                         reporter: nil)
  end

  def test_the_flag_installs_the_pool_and_a_reporter
    Minitest.parallel_executor = nil
    reporter = Minitest::CompositeReporter.new

    assert_equal :installed, Plugin.init({ ractor: true, io: StringIO.new }, {}, reporter:)
    assert_kind_of Minitest::Ractor::Executor, Minitest.parallel_executor
    assert reporter.reporters.any?(Minitest::Ractor::Reporter)
  end

  def test_init_does_nothing_when_nobody_asked
    Minitest.parallel_executor = nil
    reporter = Minitest::CompositeReporter.new

    assert_equal :not_asked, Plugin.init({}, {}, reporter:)
    assert_nil Minitest.parallel_executor
    assert_empty reporter.reporters
  end
end
