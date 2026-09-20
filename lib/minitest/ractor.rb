# frozen_string_literal: true

require_relative "ractor/version"
require_relative "ractor/errors"

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
    # ProofNotAttempted lives in ractor/errors.rb, which is a leaf that requires nothing. It has
    # to: this file loads the plugin, the plugin loads Plugin, and Plugin raises
    # ProofNotAttempted — so if Plugin reached back here for it, every run of every suite using
    # this gem would print "circular require considered harmful".

    # Used when nothing else has chosen one. Fixed rather than random, which is the opposite of
    # what Minitest does and deliberate: an audit is something you run twice, once before a fix
    # and once after, and a different dispatch order each time makes the two runs harder to
    # compare than they need to be. SEED, or an explicit argument, overrides it.
    DEFAULT_SEED = 42

    # Makes sure Minitest has a seed, and answers what it is.
    #
    # CALL THIS BEFORE ENUMERATING TESTS, not before dispatching them. Minitest::Test's own
    # .runnable_methods calls `srand Minitest.seed`, and the seed is nil until something sets
    # it, so merely asking a class what tests it has raises
    #
    #   no implicit conversion of nil into Integer (TypeError)
    #
    # from inside Kernel#srand — an error that names nothing you wrote and no seed at all.
    # Minitest.run sets the seed before init_plugins, so the plugin path never meets this. It is
    # anything driving the executor directly that does, which is the audit runner, the
    # benchmark, and anybody using Executor as a library.
    #
    # Leaves a seed somebody has already chosen alone.
    def self.seed!(value = nil, env = ENV)
      ::Minitest.seed = value if value
      ::Minitest.seed ||= (env["SEED"] || DEFAULT_SEED).to_i
      ::Minitest.seed
    end
  end
end

# Requiring this is what makes --ractor exist.
#
# Minitest 6 does not auto-discover plugins the way 5 did, so nothing registers this gem unless
# somebody asks for it by name. `require "minitest/ractor"` at the top of a test_helper is that
# ask, and it is deliberately the whole of it: the flag appears, MT_RACTOR starts being read, and
# nothing else changes until one of them says so.
#
require_relative "ractor_plugin"
