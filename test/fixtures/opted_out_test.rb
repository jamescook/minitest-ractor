# frozen_string_literal: true

require "minitest"
require "minitest/ractor"

# A test class that is ABOUT global state, and says so.
#
# Some tests exist to exercise a library's own registration — adding a plugin, a font, a
# guardrail, a middleware. Registering often defines methods on a class, which changes the whole
# process by design, and a worker may not do that. Such a test cannot run in a Ractor, and that
# is not a defect in the test: rewriting it not to touch global state would mean not testing the
# feature.
#
# Without a way to say so, a suite carrying these has two options — do not adopt the gem, or
# carry findings it can never act on. People take the second and start ignoring findings, and an
# inventory people ignore is worse than no inventory.
class OptedOutFixture < Minitest::Test
  runs_on_the_main_ractor!

  def self.registry
    @registry ||= []
  end

  def test_registers_something
    self.class.registry << :thing

    refute_empty self.class.registry
  end

  def test_registers_something_else
    self.class.registry << :other

    refute_empty self.class.registry
  end
end

Minitest::Runnable.runnables.delete OptedOutFixture
