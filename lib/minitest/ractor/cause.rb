# frozen_string_literal: true

require_relative "provenance"

module Minitest
  module Ractor
    # The underlying reason a piece of code is not Ractor-safe, identified from Ruby's own words.
    #
    # One cause typically produces many findings. A suite of 3400 tests produced 2123 failures
    # from a single memoised class ivar, and the inventory is organised by cause because the
    # cause is what somebody actually fixes: report by cause, never by test.
    #
    # EVERY PATTERN HERE WAS MEASURED, by probes/isolation_error_census.rb, which provokes each
    # refusal and prints what Ruby says. Re-run it against a new Ruby rather than trusting this
    # file — the wording is not documented anywhere and nothing will warn us when it changes.
    #
    # Two results from that census shape the whole class:
    #
    #   Ractor::UnsafeError is a SIBLING of Ractor::IsolationError, not a subclass, and two of
    #   the refusals are not Ractor exception classes at all — a plain ArgumentError and a plain
    #   RuntimeError. Matching on exception class alone drops real findings.
    #
    #   Only six of ten refusals name the offending thing. "can not set instance variables of
    #   classes/modules by non-main Ractors" says nothing about which class, so those can only be
    #   told apart by where they happened.
    class Cause
      # Matched on the distinctive middle of each sentence rather than the whole of it, so that a
      # reworded preamble does not silently stop matching. None of these overlap; the order is
      # only for reading.
      PATTERNS = [
        [:ivar_read,
         /unshareable values from instance variables.*\((?<variable>@\w+) from (?<owner>[\w:]+)\)/],
        [:ivar_write,
         %r{can not set instance variables of classes/modules}],
        [:class_variable,
         /can not access class variables.*\((?<variable>@@\w+) from (?<owner>[\w:]+)\)/],
        [:constant,
         /can not access non-shareable objects in constant (?<variable>[\w:]+)/],
        [:global_variable,
         /can not access global variable (?<variable>\$\w+)/],
        [:unsafe_method,
         /ractor unsafe method called from not main ractor/],
        [:proc_isolation,
         /can not isolate a Proc because it accesses outer variables\s*\((?<variable>[^)]*)\)/],
        [:unshareable_proc,
         /defined with an un-shareable Proc in a different Ractor/]
      ].freeze

      # What to tell somebody, and it differs by kind in a way that is easy to get wrong.
      #
      # A class ivar or a constant holding a SHAREABLE value can be read from a worker perfectly
      # well, so "make the value shareable" is a genuine one-line fix there. A class variable or
      # a global is refused even when its value is shareable — measured, not assumed — so the
      # same advice there would send somebody to freeze something that was never going to help.
      #
      # WRITTEN IN SIMPLIFIED TECHNICAL ENGLISH (ASD-STE100), and so is every other string this
      # gem prints. Short sentences, active voice, one instruction each, the imperative for
      # instructions, and one word for one thing throughout — a worker is always a worker. The
      # narrative voice of the comments stops at the quotation mark: a comment is read once by
      # somebody with time, and a remedy is read by somebody who has just watched two thousand
      # tests fail and wants to know what to change.
      REMEDIES = {
        ivar_read: "A worker can read a class or module instance variable. A worker cannot get " \
                   "an unshareable value out of one. The memoization is not the problem. Make " \
                   "the value shareable where you assign it. Use Ractor.make_shareable. If the " \
                   "value must stay mutable, change the design.",
        ivar_write: "A worker cannot write a class or module instance variable. This applies to " \
                    "all values, shareable or not. Ractor.make_shareable does not help. Set the " \
                    "variable in the main Ractor before the run, or move the state to the " \
                    "instance.",
        class_variable: "A worker cannot read a class variable. This applies even when the " \
                        "value is shareable. Ractor.make_shareable does not help. Remove the " \
                        "class variable. Usually a constant that holds a shareable value can " \
                        "replace it.",
        constant: "A worker can read a constant when the value is shareable. Make the value " \
                  "shareable: use Ractor.make_shareable where you assign it. Do not use freeze. " \
                  "A frozen Array of unfrozen Strings is still unshareable.",
        global_variable: "A worker cannot read a global variable. This applies even when the " \
                         "value is shareable. Ractor.make_shareable does not help. Remove the " \
                         "global variable.",
        unsafe_method: "This C extension is not Ractor-safe. Only the author can change this. " \
                       "The extension must call rb_ext_ractor_safe(true) in its Init_ function. " \
                       "You cannot do this from Ruby. Report the problem to the author. To " \
                       "continue, keep these tests out of the pool: add " \
                       "runs_on_the_main_ractor! to the test class.",
        proc_isolation: "This Proc reads a local variable from outside the Proc. A Ractor " \
                        "cannot isolate such a Proc. Pass the value to the Proc as an argument.",
        unshareable_proc: "A Proc that is not shareable defined this method. A worker cannot " \
                          "call it. Use Ractor.shareable_proc, or define the method with a " \
                          "string class_eval.",
        unknown: "Ruby refused this access. minitest-ractor does not recognize the message. The " \
                 "finding is reported without a remedy. Open an issue and include the Ruby " \
                 "message below."
      }.freeze

      # WHAT SOMEBODY CAN ACTUALLY DO ABOUT IT, which is a different question from what went
      # wrong and the one that decides whether the advice above is worth printing at all.
      #
      #   :yours    the thing is yours. Fix it where it is defined.
      #   :theirs   the thing is somebody else's, but the line that reached it is yours, so a
      #             copy taken in the main Ractor can stand in for it.
      #   :nobodys  neither is yours. Nothing in Ruby changes that.
      #
      # TWO QUESTIONS, NOT ONE, and asking only the first is what the report used to get wrong.
      # It told people to call make_shareable on RbConfig::CONFIG — a constant belonging to the
      # standard library, which freezing would freeze for every other gem in the process — and
      # explained how to remove Minitest::Runnable's @@runnables, which is not theirs to remove.
      TIERS = %i[yours theirs nobodys].freeze

      # Kinds where the refusal is a READ of a value, so a copy can stand in for it. A write has
      # nothing to copy, and a refusing C extension is a method call rather than a value.
      SNAPSHOTTABLE = %i[constant global_variable ivar_read class_variable].freeze

      # Kinds where the thing Ruby named can be written down as an expression, so the advice can
      # show the copy being taken instead of describing it.
      EXPRESSIBLE = %i[constant global_variable].freeze

      WHOSE = { gem: "a gem", ruby: "Ruby", native: "a C extension",
                unknown: "another library", project: "your project" }.freeze

      # The method name out of a backtrace frame: "foo.rb:12:in 'Fiddle::Handle#initialize'".
      METHOD_IN_FRAME = /:in '(?<method>.+)'\s*\z/

      # Kinds whose first frame names the CALL rather than the offence.
      #
      # A method built with define_method is a Proc, and Ruby refuses it at whatever line invoked
      # it. Measured: calling one directly reports the caller's line, and calling it from another
      # method reports that method's line. The define_method itself never appears.
      #
      # That matters because when the refused method is a TEST method, the caller is always
      # minitest — so the frame said minitest/test.rb:91 for every such test in a suite, which
      # made them all one cause however many files they came from, gave them a gem's provenance,
      # and told people a Proc in their own test file was not theirs to fix. Found by auditing a
      # real suite, where all eight of these came from two define_method calls in one file.
      #
      # Minitest records source_location on every Result, which for a define_method'd method IS
      # the block's own line, so the definition site is available and exact.
      #
      # Only used when the frame is outside the project. A define_method'd HELPER called from an
      # ordinary test already reports a frame in the test's own file, and that is a truer location
      # than the test's definition — substituting there would make things worse.
      LOCATED_AT_THE_CALL = %i[unshareable_proc].freeze

      # Kinds whose identity is the method named in the first frame rather than the frame itself.
      #
      # Ractor::UnsafeError names nothing in its message, and its first frame is the CALLER's
      # line with the refusing method's name on it. Identifying by the whole frame therefore
      # makes one unsafe C extension into one cause per call site — four call sites gave four
      # causes when measured — which is the wall of identical failures the report exists to
      # replace. The extension is what somebody fixes, so the extension is the cause.
      IDENTIFIED_BY_METHOD = %i[unsafe_method].freeze

      attr_reader :kind, :variable, :owner, :origin, :message, :tier, :owned_by, :read_by

      # Returns nil for anything that is not a refusal — that is an ordinary failure, and turning
      # one into a finding is as damaging as dropping one.
      #
      # The asymmetry is deliberate. Anything descending from Ractor::Error is a finding even if
      # the wording is unrecognised, because an unknown refusal is still a refusal and silence is
      # the worst outcome. Any other exception class is a finding ONLY if its message matches a
      # pattern we measured, because ArgumentError usually means somebody's test is wrong.
      # defined_at is where the test that hit this was written, which the classifier gets from the
      # Result. Only some kinds can use it — see LOCATED_AT_THE_CALL.
      def self.from(error, defined_at: nil)
        return nil if error.nil?

        message = error.message.to_s
        kind, match = match_for(message)
        return nil unless kind || error.is_a?(::Ractor::Error)

        kind ||= :unknown
        new(kind:, match:, message:, origin: origin_for(kind, error, defined_at))
      end

      def self.origin_for(kind, error, defined_at)
        frame = Array(error.backtrace).first
        return frame unless LOCATED_AT_THE_CALL.include? kind
        return frame if defined_at.nil? || Provenance.editable?(frame)

        defined_at
      end
      private_class_method :origin_for

      def self.match_for(message)
        PATTERNS.each do |kind, pattern|
          match = pattern.match(message)
          return [kind, match] if match
        end
        nil
      end
      private_class_method :match_for

      def initialize(kind:, message:, match: nil, origin: nil)
        @kind     = kind
        @message  = message
        @origin   = origin
        @variable = capture(match, :variable) || method_in_origin
        @owner    = capture match, :owner
        # The two questions the tier turns on, kept apart deliberately. Answering the second with
        # the first is what made the report contradict itself — see #reader_sentence.
        @owned_by = whose_thing_is_it
        @read_by  = Provenance.of @origin
        @tier     = tier_for
        freeze
      end

      # Whether Ruby told us WHAT it was unhappy about. When it did not, the only thing that can
      # tell two of these apart is where they happened.
      def named?
        !@variable.nil?
      end

      # The thing to fix, as it should be printed.
      def subject
        return nil unless named?
        return "#{@variable} from #{@owner}" if @owner

        @variable
      end

      # Cause identity, and therefore what the inventory groups by. Two findings share a cause
      # when they have the same key.
      #
      # Grouping by the named thing rather than by location is the point: one memoised ivar
      # reached from thirty call sites is ONE thing to fix, and listing it thirty times is the
      # by-test reporting this tool exists to replace. Only when Ruby names nothing does location
      # become the identity, because then it is the only handle there is.
      def key
        [@kind, subject || @origin]
      end

      # Advice somebody can act on, which means advice that matches who owns the code.
      #
      # An unrecognised refusal keeps its own answer whatever the tier: "we do not know what this
      # is" is more use than confident instructions about a thing we could not identify.
      def remedy
        return REMEDIES[:unknown] if @kind == :unknown

        case @tier
        when :theirs  then snapshot_advice
        when :nobodys then out_of_reach_advice
        else REMEDIES.fetch(@kind, REMEDIES[:unknown])
        end
      end

      def to_s
        subject ? "#{@kind}: #{subject}" : "#{@kind} at #{@origin || 'an unknown location'}"
      end

      def ==(other)
        other.is_a?(Cause) && other.key == key
      end
      alias eql? ==

      def hash
        key.hash
      end

      private

      def tier_for
        return :nobodys if @kind == :unsafe_method
        return :yours   if mine? @owned_by
        return :theirs  if SNAPSHOTTABLE.include?(@kind) && @read_by == :project

        :nobodys
      end

      # WHERE THE THING IS DEFINED, not where the refusal was raised, and they are routinely
      # different: a worker reading RbConfig::CONFIG from your own lib/catalogue.rb is refused at
      # your line. Going by the frame would call that yours and hand you advice about freezing
      # the standard library.
      #
      # When Ruby named nothing there is only the frame, which for a WRITE is the right answer
      # anyway — you write @x inside the class that owns it.
      def whose_thing_is_it
        case @kind
        when :constant                   then Provenance.of_constant @variable
        when :ivar_read, :class_variable then Provenance.of_constant @owner
        when :global_variable            then Provenance.of_global @variable
        else Provenance.of @origin
        end
      end

      # Provenance leans toward "yours" on purpose, and :unknown follows the same lean. Calling
      # something somebody else's when it was theirs to fix downgrades a finding they could have
      # acted on; calling it theirs when it was not only makes the advice more hopeful than it
      # deserved.
      def mine?(verdict)
        %i[project unknown].include? verdict
      end

      # Tier 2. The thing is somebody else's and the line that reached it is yours, so the move
      # is to stop reading theirs.
      #
      # copy: true is the load-bearing word. Without it make_shareable freezes IN PLACE, and you
      # would be freezing another library's values process-wide on its behalf. Measured: after
      # taking the copy, RbConfig::CONFIG is still unfrozen and so are its values.
      def snapshot_advice
        lead = "#{subject} belongs to #{WHOSE[@owned_by]}. You cannot change the definition. Do " \
               "not call Ractor.make_shareable on it: that freezes it for every other library " \
               "in this process. The line that reads it is in your project."

        unless EXPRESSIBLE.include?(@kind)
          return "#{lead} Read the value in the main Ractor before the run. Then pass the value " \
                 "to the test."
        end

        "#{lead} Make your own copy and read the copy: MINE = " \
          "Ractor.make_shareable(#{@variable}, copy: true). The option copy: true keeps the " \
          "original unfrozen."
      end

      # Tier 3. Neither the thing nor the line that reached it is yours, so offering a fix would
      # cost somebody an afternoon and change nothing.
      def out_of_reach_advice
        return REMEDIES[:unsafe_method] if @kind == :unsafe_method

        "#{subject || 'This state'} belongs to #{WHOSE[@owned_by]}. #{reader_sentence} You " \
          "cannot change either one. Keep these tests out of the pool: add " \
          "runs_on_the_main_ractor! to the test class. As an alternative, read the state in the " \
          "main Ractor before the run."
      end

      # WHO OWNS THE THING AND WHO READS IT ARE TWO QUESTIONS. This sentence used to answer the
      # second with the first, which was right whenever they agreed and wrong when they did not.
      # Found in the wild: a Mutex belonging to WebMock, a gem, reached from Ruby's own
      # singleton.rb. The remedy said "also belongs to a gem" two lines under a locator that said
      # "ruby code", so the report contradicted itself on one screen.
      def reader_sentence
        return "The line that reads it is not in your project." if @read_by == :unknown

        if @read_by == @owned_by
          "The line that reads it also belongs to #{WHOSE[@owned_by]}."
        else
          "The line that reads it belongs to #{WHOSE[@read_by]}."
        end
      end

      def capture(match, name)
        return nil unless match&.names&.include?(name.to_s)

        match[name]
      end

      def method_in_origin
        return nil unless IDENTIFIED_BY_METHOD.include?(@kind)

        @origin&.match(METHOD_IN_FRAME)&.[](:method)
      end
    end
  end
end
