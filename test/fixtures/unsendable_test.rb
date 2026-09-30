# frozen_string_literal: true

require "minitest"

# Tests whose results a Ractor::Port can't send as they are.
#
# A Port copies what it sends and raises if part of it can't be copied. Each test here makes
# the copy fail in a different way, which exercises the fallbacks in Executor.deliver:
#
#   An exception that Marshal.dump rejects, like CarriesAProc. Minitest replaces it with a
#   "Neutered Exception" RuntimeError before the worker sends anything.
#
#   An exception that Marshal accepts but a Port can't copy. A NameError stores its message as a
#   NameError::message object, which is one of these, so Minitest lets it through. The same goes
#   for any exception in the causes of an assertion failure, which Minitest doesn't check.
#
#   Metadata holding a Proc. Minitest asks for marshal-able data there but doesn't check.
class UnsendableFixture < Minitest::Test
  class CarriesAProc < StandardError
    def initialize(message = "an error holding a Proc")
      super
      @callback = -> { :never_called }
    end
  end

  def test_raises_something_holding_a_proc
    raise CarriesAProc
  end

  def test_puts_a_proc_in_its_metadata
    metadata[:a_proc] = -> { :never_called }

    assert_equal 4, 2 + 2
  end

  # Its #message depends on an instance variable, and that variable holds a Proc, which a Port
  # can't copy. It is raised inside assert_raises so that it becomes the cause of the assertion
  # failure. Raised directly, it would be neutered by Minitest's Marshal check first.
  class BuildsItsOwnMessage < StandardError
    def initialize
      @source = -> { "a Proc" }
      super
    end

    def message
      "built from #{@source.call}"
    end
  end

  def test_calls_a_method_that_does_not_exist
    no_such_method
  end

  def test_calls_a_method_its_object_does_not_have
    Object.new.no_such_method
  end

  def test_expects_an_argument_error_and_gets_a_name_error
    assert_raises(ArgumentError) { no_such_method }
  end

  def test_expects_an_argument_error_and_gets_one_that_builds_its_own_message
    assert_raises(ArgumentError) { raise BuildsItsOwnMessage }
  end

  def test_notes_something_then_calls_a_method_that_does_not_exist
    metadata[:note] = "kept"

    no_such_method
  end

  def test_is_perfectly_fine
    assert_equal 4, 2 + 2
  end
end

Minitest::Runnable.runnables.delete UnsendableFixture
