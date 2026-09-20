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
  FIXTURE = File.expand_path "../../fixtures/plugin_suite.rb", __dir__
  LIB     = File.expand_path "../../../lib", __dir__

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
    assert_includes output, "ProofNotAttempted"
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

  def test_the_pool_size_can_be_set_from_the_environment
    output, status = run_suite env: { "MT_RACTOR" => "1", "MT_RACTOR_WORKERS" => "1" }

    assert_predicate status, :success?, output
    assert_equal %w[worker worker], workers_in(output)
  end
end
