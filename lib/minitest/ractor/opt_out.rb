# frozen_string_literal: true

require "minitest"

module Minitest
  module Ractor
    # Lets a test class say that it is ABOUT global state, and must run in the main Ractor.
    #
    # WHY THIS IS NOT A LOOPHOLE. Some tests exist to exercise a library's own registration —
    # adding a plugin, a font, a guardrail, a middleware. Registering often defines methods on a
    # class, which changes the whole process by design, because that is what the feature IS. A
    # worker may not do that. Such a test cannot run in a Ractor, and rewriting it so that it
    # could would mean not testing the feature.
    #
    # Without a way to say so, a suite carrying these has two choices: do not adopt this gem, or
    # carry findings it can never act on. People take the second, and then they start ignoring
    # findings — and an inventory people ignore is worse than no inventory at all. The opt-out is
    # what keeps every REMAINING finding worth acting on.
    #
    # WHY IT HAS TO LIVE HERE rather than in the adopting project. Minitest has an opt-IN,
    # parallelize_me!, and no opt-out. From outside this gem the only way is to override two of
    # minitest's internals and hand-copy its own dispatch, because the parallel module has
    # already replaced that on the base class — pinned to minitest 6 and certain to break. From
    # inside, the executor simply decides where each job runs, and this is a fact it consults.
    # Nothing of minitest's is overridden or copied.
    #
    # DELIBERATELY PER-CLASS. A whole file is the honest unit when the file is about
    # registration. A per-test form would invite marking one test to silence a finding that its
    # siblings share, which is the failure mode worth designing against.
    module OptOut
      # Says this class touches process-wide state on purpose, so the pool must not try to run
      # it. Reads as a statement the class makes about itself, next to parallelize_me!.
      def runs_on_the_main_ractor!
        @runs_on_the_main_ractor = true
      end

      # Not inherited, on purpose: a class ivar belongs to the class that set it, so marking a
      # base class does not quietly opt out everything beneath it.
      def runs_on_the_main_ractor?
        @runs_on_the_main_ractor == true
      end
    end
  end
end

# On Runnable rather than on Test, so that anything minitest can run can say it.
Minitest::Runnable.extend Minitest::Ractor::OptOut
