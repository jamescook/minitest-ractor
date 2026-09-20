# frozen_string_literal: true

require_relative "cause"
require_relative "error_chain"
require_relative "finding"

module Minitest
  module Ractor
    # Turns results into findings, and findings into causes.
    #
    # The rule this enforces is the one from CONTEXT.md: a finding is never silently converted
    # into an ordinary failure, and an ordinary failure is never counted as a finding. Both
    # mistakes ruin the inventory, and the first is worse because nothing ever reveals it — a
    # dropped finding just looks like a suite with a few odd failures in it.
    #
    # WHY THE CAUSE CHAIN IS WALKED RATHER THAN THE FAILURE INSPECTED. A failure's own class is
    # not evidence of anything. assert_raises rescues `Exception => e` and flunks, so a refusal
    # arrives as a Minitest::Assertion reading "[ArgumentError] exception expected, not ..." —
    # which reads exactly like somebody's test being wrong. Against a real suite that shape
    # accounted for 260 failures at once. Checking failure.class would have discarded every one.
    module Classifier
      # The finding this result represents, or nil if it is an ordinary failure.
      #
      # Only the first refusal in a result counts. A finding belongs to exactly one cause, and a
      # test that trips over the same unsafe code twice is still one occurrence of one problem.
      def self.classify(result)
        return nil unless result.respond_to?(:failures)

        refusal_in(result) do |cause|
          return Finding.new(cause:, klass: result.klass, name: result.name, origin: cause.origin)
        end
      end

      def self.findings(results)
        results.filter_map { |result| classify result }
      end

      # Causes, each with the findings that belong to it, commonest first — the shape the
      # inventory is printed from.
      #
      # This is the whole point of the bead. A C extension that refuses is ONE thing to fix, and
      # reporting it once with a count beside it is the difference between an inventory and a
      # wall of a thousand identical failures.
      def self.by_cause(results)
        findings(results).group_by(&:cause)
                         .sort_by { |_, found| -found.size }
      end

      # Walks every failure, and every exception behind every failure, until something is
      # recognised as a refusal.
      #
      # Pass, fail and skip are not consulted. A refusal that a test caught and turned into a
      # skip is still the tool finding shared mutable state, and papering over it here would be
      # the exact thing this gem exists to stop. A passing result has no failures and so yields
      # nothing of its own accord.
      def self.refusal_in(result)
        result.failures.each do |failure|
          ErrorChain.of(failure).each do |error|
            cause = Cause.from error
            yield cause if cause
          end
        end
        nil
      end
      private_class_method :refusal_in
    end
  end
end
