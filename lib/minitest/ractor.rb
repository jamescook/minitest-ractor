# frozen_string_literal: true

require_relative "ractor/version"

module Minitest
  # Runs a Minitest suite in a pool of Ractors instead of a pool of threads, so that any shared
  # mutable state the tests reach becomes a hard error rather than a silent success.
  #
  # NAMING TRAP, and it will bite you: inside this module, a bare `Ractor` means
  # `Minitest::Ractor` — this module — and NOT Ruby's Ractor class. Lexical scope wins. So
  # every reference to Ruby's own Ractor is written `::Ractor`: `::Ractor.new`,
  # `::Ractor::Port`, `::Ractor.make_shareable`, `::Ractor::IsolationError`.
  #
  # Forgetting the `::` fails loudly and immediately (NoMethodError on a Module, or an
  # uninitialized-constant NameError), never silently, which is the only reason this namespace
  # is worth keeping. It is worth keeping because `require "minitest/ractor"` is what somebody
  # will type.
  module Ractor
    # Raised when the pool was asked for but nothing can, or did, reach a Ractor. Never let a
    # run like that report success — see docs/adr/0001.
    class ProofNotAttempted < StandardError; end
  end
end
