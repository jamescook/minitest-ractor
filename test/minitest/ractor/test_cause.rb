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
    assert_includes cause.remedy, "does not recognize the message"
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

  # The brief's one explicit demand on the report: a C extension that refuses must surface as ONE
  # cause, not hundreds. Ractor::UnsafeError names nothing, and its first frame is the CALLER's
  # line carrying the refusing method's name — so identifying it by the frame makes one unsafe
  # extension into one cause per call site: four call sites gave four causes when measured.
  #
  # Uses a real refusal rather than a built one, and says so when it cannot get one: most stdlib
  # C extensions have been made Ractor-safe and Fiddle may follow, at which point this needs a
  # new specimen rather than a quiet pass.
  def unsafe_method_refusal(&)
    require "fiddle"
    refusal(&)
  end

  def test_a_refusing_c_extension_is_one_cause_however_many_places_reach_it
    first  = Cause.from(unsafe_method_refusal { Fiddle::Handle.new })
    second = Cause.from(unsafe_method_refusal { [Fiddle::Handle.new] })

    skip "Fiddle no longer refuses; find another Ractor-unsafe extension" if first.nil?

    assert_equal :unsafe_method, first.kind
    assert_equal "Fiddle::Handle#initialize", first.subject
    assert_equal first, second, "two call sites into one extension are one thing to fix"
  end

  def test_unnamed_causes_in_different_places_are_different_causes
    first  = Cause.new kind: :ivar_write, message: "x", origin: "a.rb:1:in 'x'"
    second = Cause.new kind: :ivar_write, message: "x", origin: "b.rb:2:in 'y'"

    refute_equal first, second
    assert_equal 2, [first, second].uniq.size
  end

  # The advice has to differ, and getting it uniform would be worse than saying nothing: a class
  # ivar holding a shareable value IS readable from a worker, while a class variable holding one
  # is still refused. Measured, and this test provokes both from live Ractors to keep it so.
  def test_the_remedy_offers_make_shareable_only_where_it_would_actually_work
    ivar     = Cause.from(refusal { UnshareableIvar.read })
    constant = Cause.from(refusal { UNSHAREABLE_CONSTANT.first })
    cvar     = Cause.from(refusal { ClassVariable.read })
    global   = Cause.from(refusal { $test_cause_global }) # rubocop:disable Style/GlobalVars

    assert_includes ivar.remedy, "Ractor.make_shareable"
    assert_includes constant.remedy, "Ractor.make_shareable"
    assert_includes cvar.remedy, "does not help"
    assert_includes global.remedy, "does not help"
  end

  # The bead's first design note: do not tell somebody they cannot memoise on a class. Often they
  # can, and saying otherwise sends them to rewrite code that was fine.
  def test_the_remedy_for_a_readable_ivar_does_not_condemn_memoisation
    remedy = Cause.from(refusal { UnshareableIvar.read }).remedy

    assert_includes remedy, "A worker can read a class or module instance variable"
    assert_includes remedy, "The memoization is not the problem"
  end

  # TIERS. What somebody can do about a finding is a different question from what went wrong, and
  # the report used to answer only the second one — telling people to freeze constants belonging
  # to the standard library and to delete class variables belonging to minitest.

  def test_a_finding_in_your_own_code_is_yours_to_fix
    assert_equal :yours, Cause.from(refusal { UnshareableIvar.read }).tier
    assert_equal :yours, Cause.from(refusal { UNSHAREABLE_CONSTANT.first }).tier
  end

  # THE CASE THIS WAS BUILT FOR, and the one the backtrace alone gets wrong. The refusal is raised
  # at the line in THIS file that reads the constant, so going by the frame would call it ours and
  # advise freezing RbConfig's strings on behalf of every other library in the process.
  def test_somebody_elses_constant_read_from_your_line_gets_a_workaround
    cause = Cause.from(refusal { RbConfig::CONFIG["host"] })

    assert_equal :ruby, cause.owned_by, "the constant belongs to ruby even though the line is ours"
    assert_equal :theirs, cause.tier
    assert_includes cause.remedy, "copy: true"
    refute_includes cause.remedy, "where you assign it", "we cannot assign somebody else's constant"
  end

  # Ruby's own globals, for the same reason: $LOAD_PATH was the largest single cause in one real
  # suite, and "Remove the global variable" is not something anybody can do about $LOAD_PATH.
  def test_rubys_own_global_gets_a_workaround_and_not_an_order_to_delete_it
    cause = Cause.from(refusal { $LOAD_PATH.first })

    assert_equal :theirs, cause.tier
    assert_includes cause.remedy, "copy: true"
    refute_includes cause.remedy, "Remove the global variable"
  end

  def test_your_own_global_is_still_yours_to_remove
    cause = Cause.from(refusal { $test_cause_global }) # rubocop:disable Style/GlobalVars

    assert_equal :yours, cause.tier
    assert_includes cause.remedy, "Remove the global variable"
  end

  # Neither the class variable nor the line that reaches it is ours, so there is nothing to
  # suggest except keeping it out of the pool.
  def test_a_class_variable_in_somebody_elses_code_can_be_fixed_by_nobody
    cause = Cause.from(refusal { ::Minitest::Runnable.runnables })

    assert_equal :nobodys, cause.tier
    assert_includes cause.remedy, "runs_on_the_main_ractor!"
    refute_includes cause.remedy, "Remove the class variable"
  end

  # Always tier 3, whoever wrote the line that reached it: the fix is in C, in somebody else's
  # Init_ function, and no amount of editing Ruby changes that.
  def test_a_refusing_c_extension_is_nobodys_to_fix_even_from_your_own_line
    cause = Cause.from(unsafe_method_refusal { Fiddle::Handle.new })

    skip "Fiddle no longer refuses; find another Ractor-unsafe extension" if cause.nil?

    assert_equal :nobodys, cause.tier
    assert_includes cause.remedy, "rb_ext_ractor_safe"
  end

  # THE TWO EDGES of substituting the definition site for the frame. The message is Ruby's own,
  # taken from a real refusal; only the backtrace is written by hand, because reproducing "called
  # from inside a gem" needs a gem, and what is under test is which location wins.
  class ProcBuilt
    define_method(:refused) { :ok }
  end

  IN_A_GEM = "#{Gem.default_dir}/gems/minitest-6.0.6/lib/minitest/test.rb:91:in 'block in run'".freeze

  def proc_refusal
    refusal { ProcBuilt.new.refused }
  end

  def test_a_proc_refused_inside_a_gem_takes_the_definition_site_instead
    error = proc_refusal
    error.set_backtrace [IN_A_GEM]

    cause = Cause.from error, defined_at: "test/some_test.rb:12"

    assert_equal "test/some_test.rb:12", cause.origin
    assert_equal :yours, cause.tier
  end

  # A define_method'd HELPER called from an ordinary test already reports a frame in the test's
  # own file, which is a truer location than the test's definition. Substituting there would move
  # a correct answer to a worse one.
  def test_a_proc_refused_in_your_own_code_keeps_the_frame_it_came_with
    cause = Cause.from proc_refusal, defined_at: "test/somewhere_else.rb:99"

    assert_includes cause.origin, "test_cause.rb"
    refute_equal "test/somewhere_else.rb:99", cause.origin
  end

  # proc_isolation reports at Ractor.new, which is the line somebody wrote, so the frame is
  # already right. Measured before excluding it: the proc's own definition never appears, but
  # neither does anything belonging to minitest.
  def test_proc_isolation_is_left_on_its_own_frame
    outer = +"captured"
    cause = Cause.from refusal { outer }, defined_at: "test/somewhere_else.rb:99"

    assert_equal :proc_isolation, cause.kind
    refute_equal "test/somewhere_else.rb:99", cause.origin
  end

  # WHO OWNS IT AND WHO READS IT ARE TWO QUESTIONS, and a tier-3 remedy has to answer both. Found
  # in the wild: a Mutex belonging to WebMock, a gem, reached from Ruby's own singleton.rb. The
  # advice said "also belongs to a gem" directly under a locator saying "ruby code".
  #
  # @io_lock is the same shape and needs no extra dependency — a Mutex on a class minitest owns.
  # The message is Ruby's own; only the frame is written here, because reproducing "read from
  # inside the standard library" needs the standard library, and the frame is what is under test.
  RUBY_FRAME = "#{RbConfig::CONFIG['rubylibdir']}/singleton.rb:128:in 'instance'".freeze

  def a_gems_mutex_read_from_ruby
    error = refusal { ::Minitest::Test.instance_variable_get(:@io_lock) }
    error.set_backtrace [RUBY_FRAME]
    Cause.from error
  end

  def test_the_thing_and_the_line_that_reads_it_are_reported_separately
    cause = a_gems_mutex_read_from_ruby

    assert_equal :gem, cause.owned_by, "the mutex is minitest's"
    assert_equal :ruby, cause.read_by, "the line that reads it is the standard library's"

    assert_includes cause.remedy, "belongs to a gem"
    assert_includes cause.remedy, "The line that reads it belongs to Ruby"
  end

  # The report must not contradict its own locator, which is what gave this away.
  def test_the_remedy_does_not_claim_the_reader_belongs_to_the_owner
    refute_includes a_gems_mutex_read_from_ruby.remedy, "also belongs to a gem"
  end

  # ...and when they really are the same, saying it twice reads badly, so that case keeps "also".
  def test_one_owner_for_both_is_still_said_once
    cause = Cause.from(refusal { ::Minitest::Runnable.runnables })

    assert_equal cause.owned_by, cause.read_by
    assert_includes cause.remedy, "also belongs to a gem"
  end

  # An unrecognised refusal keeps its own answer whatever the tier. "We do not know what this is"
  # is worth more than confident instructions about something we could not identify.
  def test_an_unrecognised_refusal_keeps_its_own_remedy
    cause = Cause.new kind: :unknown, message: "something new", origin: "#{Gem.default_dir}/x.rb:1"

    assert_includes cause.remedy, "does not recognize the message"
  end
end
