# frozen_string_literal: true

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
      REMEDIES = {
        ivar_read: "A worker MAY read a class or module instance variable. What it may not do " \
                   "is get an unshareable value out of one. So the memoisation is not the " \
                   "problem and usually does not have to go: make the value shareable where it " \
                   "is assigned, with Ractor.make_shareable. Only a value that has to stay " \
                   "mutable forces a redesign.",
        ivar_write: "A worker may not WRITE a class or module instance variable at all, " \
                    "shareable value or not, so make_shareable will not help here. Either warm " \
                    "it in the main Ractor before the run, or move the state onto the instance.",
        class_variable: "A worker may not read a class variable even when its value is " \
                        "shareable, so make_shareable will not help. The class variable itself " \
                        "has to go; a constant holding a shareable value is the usual swap.",
        constant: "A worker may read a constant whose value is shareable, so this is a one-line " \
                  "fix: Ractor.make_shareable on the value. Note that freeze alone is not " \
                  "enough — an Array of unfrozen Strings is frozen and still refused.",
        global_variable: "A worker may not read an ordinary global even when its value is " \
                         "shareable, so make_shareable will not help. The global has to go.",
        unsafe_method: "A C extension that never declared itself Ractor-safe. Nothing can be " \
                       "done to it from Ruby: it needs a fix upstream, or the tests that reach " \
                       "it have to stay out of the pool.",
        proc_isolation: "A Proc given to a Ractor closed over a local variable. Pass the value " \
                        "in as an argument instead of capturing it.",
        unshareable_proc: "Something was defined with a Proc that is not shareable and is now " \
                          "being reached from another Ractor.",
        unknown: "Ruby refused this and minitest-ractor does not recognise the wording. It is " \
                 "reported as-is rather than dropped. Please open an issue with the message " \
                 "below, and re-run probes/isolation_error_census.rb."
      }.freeze

      attr_reader :kind, :variable, :owner, :origin, :message

      # Returns nil for anything that is not a refusal — that is an ordinary failure, and turning
      # one into a finding is as damaging as dropping one.
      #
      # The asymmetry is deliberate. Anything descending from Ractor::Error is a finding even if
      # the wording is unrecognised, because an unknown refusal is still a refusal and silence is
      # the worst outcome. Any other exception class is a finding ONLY if its message matches a
      # pattern we measured, because ArgumentError usually means somebody's test is wrong.
      def self.from(error)
        return nil if error.nil?

        message = error.message.to_s
        kind, match = match_for(message)
        return nil unless kind || error.is_a?(::Ractor::Error)

        new(kind: kind || :unknown, match:, message:, origin: Array(error.backtrace).first)
      end

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
        @variable = capture match, :variable
        @owner    = capture match, :owner
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

      def remedy
        REMEDIES.fetch(@kind, REMEDIES[:unknown])
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

      def capture(match, name)
        return nil unless match&.names&.include?(name.to_s)

        match[name]
      end
    end
  end
end
