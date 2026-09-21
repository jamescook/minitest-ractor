# frozen_string_literal: true

require "test_helper"
require "open3"

# The plugin end to end, in real subprocesses.
#
# Everything this gem gets wrong about opt-in, it gets wrong because of ORDER: what Minitest has
# loaded by the time a flag becomes readable, and what parallelize_me! already decided before
# that. None of it can be tested in a process that has finished loading, so these shell out.
#
# The fixture requires "minitest/ractor" the way a test_helper would, which is the whole of how
# this plugin gets registered: Minitest.run never calls load_plugins, so there is no discovery to
# simulate. What these exercise is the real path a user takes.
class TestPluginIntegration < Minitest::Test
  FIXTURE        = File.expand_path "../../fixtures/plugin_suite.rb", __dir__
  UNPARALLELISED = File.expand_path "../../fixtures/unparallelised_suite.rb", __dir__
  SLOW           = File.expand_path "../../fixtures/slow_suite.rb", __dir__
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
  # The people at risk are the ones who asked for this gem by name, and they are exactly the ones
  # it must not surprise: wanting Ractors in CI is not the same as wanting them on every run.
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

  # Ctrl+C, in a real process, because there is nowhere else it can be tested: what was wrong was
  # entirely about what minitest does AFTER an Interrupt is rescued, and about the exit status.
  #
  # Waits for the suite to say it is running before signalling, rather than guessing at how long
  # a Ruby process takes to boot on a machine somebody else is also using.
  def interrupt_mid_run
    command = [BASE_ENV.merge("MT_RACTOR_WORKERS" => "2"), RbConfig.ruby, "-W0", "-I#{LIB}",
               SLOW, "--ractor"]

    Open3.popen2e(*command) do |stdin, out, wait|
      stdin.close
      running = out.gets # nil means it died before it ever started; the assertions will say so

      if running
        sleep 0.5 # long enough for a few tests to finish, so there is a pile to NOT print
        Process.kill "INT", wait.pid
      end

      ["#{running}#{out.read}", wait.value]
    end
  end

  # What it used to do: rescue the Interrupt, drain every test still in flight, and then print all
  # 36 failures it had collected with their backtraces — 247 lines arriving after the signal, at
  # a prompt the user already had back.
  def test_ctrl_c_stops_the_run_without_emptying_itself_into_the_terminal
    output, = interrupt_mid_run

    assert_includes output, "Interrupted after", "an interrupted run still has to say so"
    refute_includes output, "Error:", "the failures it had collected are not worth printing now"
    refute_includes output, "runs,", "and neither is minitest's summary of a run that did not end"
  end

  # THE PRINCIPLED HALF. The inventory's counts, its coverage line and its NO PROOF check are all
  # claims about a COMPLETE run. Printed for a partial one they are simply false: an interrupted
  # 120-test run reported "36 of 36 tests ran in Ractors", which reads as full coverage.
  def test_an_interrupted_run_claims_no_proof_at_all
    output, = interrupt_mid_run

    refute_includes output, "minitest-ractor:", "a run that did not finish has no inventory"
    refute_includes output, "ran in Ractors", "and no coverage figure either"
  end

  # 128 + SIGINT, so a shell and a CI runner both read it as "somebody stopped this", rather than
  # as the test failure it used to exit with.
  def test_an_interrupted_run_exits_with_the_signal_status
    _, status = interrupt_mid_run

    assert_equal 130, status.exitstatus
  end

  def test_the_pool_size_can_be_set_from_the_environment
    output, status = run_suite env: { "MT_RACTOR" => "1", "MT_RACTOR_WORKERS" => "1" }

    assert_predicate status, :success?, output
    assert_equal %w[worker worker], workers_in(output)
  end
end
