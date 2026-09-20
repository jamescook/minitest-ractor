# frozen_string_literal: true

module Minitest
  module Ractor
    # Every exception a failure can be explained by, outermost first.
    #
    # A failure is often not where the interesting thing happened. assert_raises rescues
    # `Exception => e` and calls flunk, so an isolation error arrives dressed as an ordinary
    # Minitest::Assertion with frames pointing at assert_raises; the refusal that matters is one
    # link down. A Ractor that dies does the same thing — RemoteError on top, the real exception
    # underneath. Anything asking "what actually went wrong here" has to walk to the bottom.
    #
    # Two callers, which is why this is not a private method on either of them: the worker lifts
    # backtraces off this chain before sending a result home, and the classifier reads causes off
    # it once the result arrives.
    module ErrorChain
      # How far to follow. Ruby will not let an exception cause itself, but a chain assembled by
      # hand can still loop, and one caller is inside a worker where a hang costs the whole pool.
      # Ten is far past anything real.
      DEPTH = 10

      # Where a failure's backtrace actually lives. Minitest wraps anything that is not an
      # assertion in UnexpectedError, which delegates #backtrace to the error it holds, so frames
      # set on the wrapper would not stick.
      def self.holder(failure)
        failure.respond_to?(:error) ? failure.error : failure
      end

      def self.of(failure)
        chain   = [holder(failure)]
        current = chain.first

        while (current = current.cause) && chain.size < DEPTH
          chain << current
        end

        chain
      end
    end
  end
end
