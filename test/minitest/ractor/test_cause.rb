# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/cause"

class TestCause < Minitest::Test
  Cause = Minitest::Ractor::Cause

  # Specimens. Each is the smallest thing that makes Ruby say one particular sentence.
  class UnshareableIvar
    @value = +"mutable"

    def self.read = @value
    # Deliberately a second reader on its own line: one ivar reached from two places is the
    # case that says whether grouping is by the thing or by the location.
    def self.read_elsewhere = @value
    def self.write = (@value = +"written")
  end

  class ClassVariable
    @@value = +"mutable" # rubocop:disable Style/ClassVars

    def self.read = @@value
  end

  # Frozen Array, unfrozen String inside: frozen is not shareable, and that gap is why this gem
  # says make_shareable everywhere it could say freeze.
  UNSHAREABLE_CONSTANT = [+"mutable"].freeze

  $test_cause_global = +"mutable" # rubocop:disable Style/GlobalVars

  # Every message asserted on here came out of a real Ractor during this test run, never out of a
  # string literal. The classifier exists to understand what Ruby actually says; a test written
  # against remembered text proves only that two copies of my memory agree, and would keep
  # passing after Ruby changed the wording — which is the one failure that matters.
  def refusal(&)
    # Every Ractor here is meant to die, and Ruby prints each death to stderr.
    was = Thread.report_on_exception
    Thread.report_on_exception = false

    ::Ractor.new(&).value

    flunk "expected Ruby to refuse this"
  rescue StandardError => e
    # A Ractor that dies re-raises in the reader wrapped in RemoteError, with the real exception
    # underneath — the same shape as assert_raises swallowing one.
    root = e
    root = root.cause while root.cause
    root
  ensure
    Thread.report_on_exception = was
  end

  def test_an_unshareable_class_ivar_names_the_variable_and_its_owner
    cause = Cause.from(refusal { UnshareableIvar.read })

    assert_equal :ivar_read, cause.kind
    assert_equal "@value", cause.variable
    assert_equal "TestCause::UnshareableIvar", cause.owner
  end

  def test_a_class_variable_names_the_variable_and_its_owner
    cause = Cause.from(refusal { ClassVariable.read })

    assert_equal :class_variable, cause.kind
    assert_equal "@@value", cause.variable
    assert_equal "TestCause::ClassVariable", cause.owner
  end

  def test_an_unshareable_constant_names_the_constant
    cause = Cause.from(refusal { UNSHAREABLE_CONSTANT.first })

    assert_equal :constant, cause.kind
    assert_includes cause.variable, "UNSHAREABLE_CONSTANT"
  end

  def test_a_global_variable_names_the_global
    cause = Cause.from(refusal { $test_cause_global }) # rubocop:disable Style/GlobalVars

    assert_equal :global_variable, cause.kind
    assert_equal "$test_cause_global", cause.variable
  end

  # The commonest real-world shape — memoising on the class — and the one Ruby says least about.
  # It names no variable and no owner, so the only thing that can tell two of them apart is where
  # they happened.
  def test_writing_a_class_ivar_names_nothing_and_falls_back_to_where_it_happened
    cause = Cause.from(refusal { UnshareableIvar.write })

    assert_equal :ivar_write, cause.kind
    refute_predicate cause, :named?
    assert_nil cause.subject
    assert_includes cause.key.last.to_s, "test_cause.rb"
  end

  # The asymmetry, first direction. A refusal we cannot parse is still a refusal, and dropping it
  # for being unfamiliar is the one outcome with no recovery: nobody ever learns it happened.
  def test_an_unrecognised_ractor_error_is_still_a_finding
    error = ::Ractor::IsolationError.new "some wording Ruby does not use yet"
    error.set_backtrace ["somewhere.rb:1:in 'x'"]

    cause = Cause.from error

    assert_equal :unknown, cause.kind
    assert_includes cause.message, "wording Ruby does not use yet"
    assert_includes cause.remedy, "does not recognise"
  end

  # The asymmetry, second direction. Counting an ordinary failure as a finding corrupts the
  # inventory just as badly, so anything that is not a Ractor error has to earn it on the message.
  def test_an_ordinary_failure_is_not_a_finding
    assert_nil Cause.from(ArgumentError.new("wrong number of arguments (given 1, expected 2)"))
    assert_nil Cause.from(RuntimeError.new("something broke"))
    assert_nil Cause.from(nil)
  end

  # ...and the reason that rule is on the message rather than the class: two of the refusals Ruby
  # produces are not Ractor exception classes at all. This one is a plain ArgumentError.
  def test_a_refusal_raised_as_a_plain_argument_error_is_still_a_finding
    outer = 1
    error = begin
      ::Ractor.new(&-> { outer })

      flunk "expected Ruby to refuse to isolate this Proc"
    rescue StandardError => e
      e
    end

    assert_kind_of ArgumentError, error, "the premise of this test is that it is NOT a Ractor error"
    assert_equal :proc_isolation, Cause.from(error).kind
  end

  # What makes the inventory an inventory. One memoised ivar reached from thirty places is one
  # thing to fix; listing it thirty times is the by-test reporting this replaces.
  def test_the_same_named_thing_is_one_cause_wherever_it_was_reached
    here  = Cause.from(refusal { UnshareableIvar.read })
    there = Cause.from(refusal { UnshareableIvar.read_elsewhere })

    refute_equal here.origin, there.origin, "the premise is that these happened in different places"
    assert_equal here, there
    assert_equal 1, [here, there].uniq.size
  end

  def test_unnamed_causes_in_different_places_are_different_causes
    first  = Cause.new kind: :ivar_write, message: "x", origin: "a.rb:1:in 'x'"
    second = Cause.new kind: :ivar_write, message: "x", origin: "b.rb:2:in 'y'"

    refute_equal first, second
    assert_equal 2, [first, second].uniq.size
  end

  # The advice has to differ, and getting it uniform would be worse than saying nothing: a class
  # ivar holding a shareable value IS readable from a worker, while a class variable holding one
  # is still refused. Measured in probes/isolation_error_census.rb.
  def test_the_remedy_offers_make_shareable_only_where_it_would_actually_work
    ivar     = Cause.from(refusal { UnshareableIvar.read })
    constant = Cause.from(refusal { UNSHAREABLE_CONSTANT.first })
    cvar     = Cause.from(refusal { ClassVariable.read })
    global   = Cause.from(refusal { $test_cause_global }) # rubocop:disable Style/GlobalVars

    assert_includes ivar.remedy, "make_shareable"
    assert_includes constant.remedy, "make_shareable"
    assert_includes cvar.remedy, "will not help"
    assert_includes global.remedy, "will not help"
  end

  # The bead's first design note: do not tell somebody they cannot memoise on a class. Often they
  # can, and saying otherwise sends them to rewrite code that was fine.
  def test_the_remedy_for_a_readable_ivar_does_not_condemn_memoisation
    remedy = Cause.from(refusal { UnshareableIvar.read }).remedy

    assert_includes remedy, "MAY read"
    assert_includes remedy, "does not have to go"
  end
end
