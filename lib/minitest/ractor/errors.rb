# frozen_string_literal: true

module Minitest
  # NAMING TRAP, and it will bite you: inside this module, a bare `Ractor` means
  # `Minitest::Ractor` — this module — and NOT Ruby's Ractor class. Lexical scope wins. So every
  # reference to Ruby's own Ractor is written `::Ractor`: `::Ractor.new`, `::Ractor::Port`,
  # `::Ractor.make_shareable`, `::Ractor::IsolationError`.
  module Ractor
    # Raised when the pool was asked for but nothing can, or did, reach a Ractor. A green run
    # that touched no Ractor is the worst failure this tool has, because it is indistinguishable
    # from success and hands back a proof that was never attempted. So it is an error, never a
    # warning, and the run stops.
    class ProofNotAttempted < StandardError; end
  end
end

# A LEAF ON PURPOSE. It requires nothing, because minitest/ractor.rb loads the plugin, the plugin
# loads Plugin, and Plugin needs ProofNotAttempted — which is a circle if that last step reaches
# back for the front door. Ruby permits the circle and prints "circular require considered
# harmful" on every run of every suite that uses this gem, which is not a thing to inflict on
# somebody to save a file.
