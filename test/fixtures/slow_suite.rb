# frozen_string_literal: true

# A suite slow enough to interrupt, for the Ctrl+C integration test to run in a subprocess.
#
# Two things are deliberate. It is SLOW, because a run that is over cannot be interrupted and a
# fixed sleep in the parent would be a race on a loaded machine. And every test FAILS, because
# what Ctrl+C used to produce was minitest printing every failure it had collected, each with a
# backtrace, after the signal — so a green suite here would prove nothing about the fix.
#
# Each test announces itself on stderr, which is unbuffered, so the parent can wait for the run
# to actually be under way instead of guessing at how long this takes to boot. The progress dots
# go to stdout and are block-buffered into the pipe, which is no use for that.

require "minitest/autorun"
require "minitest/ractor"

class Catalogue
  def self.index
    @index ||= { "a" => 1 }
  end
end

class SlowFixture < Minitest::Test
  parallelize_me!

  # Generated with a string class_eval rather than define_method: a block is a Proc, a Proc is
  # unshareable, and the finding would then be about this file rather than about Catalogue.
  16.times do |i|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      # def test_slow_0
      #   $stderr.puts "RUNNING"
      #   sleep 0.25
      #
      #   refute_empty Catalogue.index
      # end
      def test_slow_#{i}
        $stderr.puts "RUNNING"
        sleep 0.25

        refute_empty Catalogue.index
      end
    RUBY
  end
end
