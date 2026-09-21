# frozen_string_literal: true

# A whole minitest suite in a file, for the plugin's integration tests to run in a subprocess.
#
# The plugin's entire job is about ORDER — what is loaded before what, and what is readable when
# — so it cannot be tested honestly in a process that has already loaded everything.
#
# The two requires are exactly what a real test_helper would have, in the order it would have
# them: minitest first, then this gem, both before any test class exists. Minitest loads a plugin
# only when a suite asks for it, so requiring it by name is the whole opt-in — and it must still
# leave the suite alone until --ractor or MT_RACTOR says otherwise.
#
# Each test says where it ran, and the suite says what executor it ended up with. That is enough
# to tell "ran in a pool of Ractors" from "reported success without going near one", which is the
# distinction the opt-in design exists to protect.

require "minitest/autorun"
require "minitest/ractor"

class PluginSuite < Minitest::Test
  parallelize_me!

  def where
    ::Ractor.current == ::Ractor.main ? "main" : "worker"
  end

  # These have to pass wherever they run — the integration test reads the marker to decide where
  # that was, and a failing test here would muddle "the pool did not engage" with "the suite is
  # broken". Asserting the marker itself keeps them honest without making them fragile.
  def test_one
    $stdout.puts "WHERE: #{where}"

    assert_includes %w[main worker], where
  end

  def test_two
    $stdout.puts "WHERE: #{where}"

    assert_includes %w[main worker], where
  end
end

Minitest.after_run do
  $stdout.puts "EXECUTOR: #{Minitest.parallel_executor.class}"
  $stdout.puts "PARALLEL: #{PluginSuite.run_order}"
end
