# frozen_string_literal: true

require "test_helper"
require "open3"

# The plugin end to end, in real subprocesses.
#
# Everything this gem gets wrong about opt-in, it gets wrong because of ORDER: what Minitest has
# loaded by the time a flag becomes readable, and what parallelize_me! already decided before
# that. None of it can be tested in a process that has finished loading, so these shell out.
#
# The fixture requires "minitest/ractor" the way a test_helper would, which on minitest 6 is the
# whole of how a plugin gets registered: load_plugins is no longer called for you, so there is no
# discovery to simulate. What these exercise is the real path a user takes.
class TestPluginIntegration < Minitest::Test
  FIXTURE        = File.expand_path "../../fixtures/plugin_suite.rb", __dir__
  UNPARALLELISED = File.expand_path "../../fixtures/unparallelised_suite.rb", __dir__
  LIB            = File.expand_path "../../../lib", __dir__

  # The parent process may have any of these set; a test about environment variables cannot
  # inherit an environment. Nil tells Open3 to unset.
  BASE_ENV = { "MT_CPU" => nil, "MT_RACTOR" => nil, "MT_RACTOR_WORKERS" => nil }.freeze

  def run_suite(env: {}, args: [])
    output, status = Open3.capture2e BASE_ENV.merge(env), RbConfig.ruby, "-W0", "-I#{LIB}",
                                     FIXTURE, *args
    [output, status]
  end

  # Deliberately unanchored: Minitest's progress dots share the line, so the second test's marker
  # arrives as ".WHERE: main".
  def workers_in(output)
    output.scan(/WHERE: (\w+)/).flatten.sort
  end

  # Requiring the gem must be silent under -w.
  #
  # It was not: minitest/ractor.rb loads the plugin, the plugin loads Plugin, and Plugin reached
  # back here for ProofNotAttempted, so every run of every suite using this gem printed "circular
  # require considered harmful". Nothing caught it because this suite and every probe run with
  # -W0 — the flag people reach for to silence Ruby's Ractor warning silences this too. Reported
  # from a real project, not found here.
  def test_requiring_the_gem_warns_about_nothing
    output, status = Open3.capture2e BASE_ENV, RbConfig.ruby, "-w", "-I#{LIB}",
                                     "-e", 'require "minitest/ractor"'

    assert_predicate status, :success?, output
    refute_match(/circular require/, output)
    refute_match(/warning/i, output, "requiring this gem should say nothing at all")
  end

  # THE GUARANTEE. The fixture requires this gem, the way a test_helper would, and then runs
  # without asking for Ractors. Nothing may change: same executor, same place, no inventory.
  #
  # On minitest 5 this test was about something stronger — load_plugins required every installed
  # gem's plugin file on every run, so merely INSTALLING this could have hijacked suites that had
  # never heard of it. Minitest 6 dropped that, so the risk is now only to people who asked for
  # the gem by name. It still must not surprise them: wanting Ractors in CI is not the same as
  # wanting them on every run.
  def test_requiring_the_gem_does_not_hijack_a_suite
    output, status = run_suite

    assert_predicate status, :success?, output
    refute_includes output, "Minitest::Ractor::Executor", "the pool must not install itself"
    refute_includes output, "minitest-ractor:", "and it must not print an inventory either"
    assert_equal %w[main main], workers_in(output), "tests should run where they always did"
  end

  def test_the_flag_runs_every_test_in_a_worker
    output, status = run_suite args: ["--ractor"]

    assert_predicate status, :success?, output
    assert_includes output, "EXECUTOR: Minitest::Ractor::Executor"
    assert_equal %w[worker worker], workers_in(output), "every test should have left the main Ractor"
  end

  def test_the_flag_prints_the_inventory
    output, = run_suite args: ["--ractor"]

    assert_includes output, "minitest-ractor: no findings"
    assert_includes output, "THESE TESTS REACHED", "a green run states the limit of what it proved"
  end

  # THE HOLE. Under MT_CPU=1 minitest builds no executor, so parallelize_me! did nothing long
  # before --ractor could be read. Left alone this reports a cheerful green run that never went
  # near a Ractor, which is the worst outcome this gem has.
  def test_the_flag_alone_with_threads_disabled_refuses_to_run
    output, status = run_suite env: { "MT_CPU" => "1" }, args: ["--ractor"]

    refute_predicate status, :success?, "a proof that cannot be attempted must not exit green"
    assert_includes output, "minitest-ractor:"
    refute_includes output, "plugin.rb:", "a mistyped command deserves a sentence, not a backtrace"
    assert_includes output, "MT_RACTOR=1", "the error has to name the fix"
    assert_empty workers_in(output), "and no test should have run at all"
  end

  # ...and the environment variable is the way through, because it is readable before the test
  # files load, which is the only moment that can get in front of parallelize_me!.
  def test_the_env_var_survives_threads_being_disabled
    output, status = run_suite env: { "MT_CPU" => "1", "MT_RACTOR" => "1" }

    assert_predicate status, :success?, output
    assert_equal %w[worker worker], workers_in(output)
    assert_includes output, "PARALLEL: parallel", "parallelize_me! has to have taken"
  end

  # The debugging switch. MT_RACTOR exported in a shell or set on a CI job is otherwise
  # impossible to turn off for one run, and "run this the normal way once" is the first thing
  # anybody does when a finding looks wrong.
  def test_declining_on_the_command_line_beats_the_environment
    output, status = run_suite env: { "MT_RACTOR" => "1" }, args: ["--no-ractor"]

    assert_predicate status, :success?, output
    assert_equal %w[main main], workers_in(output), "no test should have gone near a Ractor"
    refute_includes output, "minitest-ractor:", "and no inventory should be printed"
  end

  # Declining after MT_RACTOR already installed the pool at load time is the interesting half:
  # parallelize_me! has run by then, so the classes are parallel and something still has to
  # dispatch them.
  def test_declining_leaves_a_working_suite_even_with_threads_disabled
    output, status = run_suite env: { "MT_RACTOR" => "1", "MT_CPU" => "1" }, args: ["--no-ractor"]

    assert_predicate status, :success?, output
    assert_equal %w[main main], workers_in(output)
    assert_includes output, "2 runs", "both tests still have to run"
  end

  # PRE-FLIGHT, end to end. By init_plugins every class is loaded and its run_order is settled,
  # so a suite that cannot possibly reach a Ractor is refused before a single test runs — in
  # milliseconds, rather than after ten minutes of proving nothing.
  def test_a_suite_that_cannot_reach_a_ractor_is_refused_before_it_runs
    output, status = Open3.capture2e BASE_ENV, RbConfig.ruby, "-W0", "-I#{LIB}",
                                     UNPARALLELISED, "--ractor"

    refute_predicate status, :success?
    assert_includes output, "minitest-ractor:"
    refute_includes output, "plugin.rb:", "a mistyped command deserves a sentence, not a backtrace"
    assert_includes output, "parallelize_me!", "it has to name the likely reason"
    refute_includes output, "RAN:", "and no test should have run at all"
  end

  # The same suite is left alone when nobody asked for Ractors. Pre-flight is not a general
  # opinion about how people should write tests.
  def test_a_suite_that_cannot_reach_a_ractor_is_fine_if_it_never_asked
    output, status = Open3.capture2e BASE_ENV, RbConfig.ruby, "-W0", "-I#{LIB}", UNPARALLELISED

    assert_predicate status, :success?, output
    assert_includes output, "RAN: test_one"
  end

  def test_the_pool_size_can_be_set_from_the_environment
    output, status = run_suite env: { "MT_RACTOR" => "1", "MT_RACTOR_WORKERS" => "1" }

    assert_predicate status, :success?, output
    assert_equal %w[worker worker], workers_in(output)
  end
end
