# frozen_string_literal: true

# Not a test — a specimen. Every file under lib/minitest/ractor/ is written in this nesting,
# and this is the only way to observe what a bare `Ractor` means there. `module_eval` cannot
# stand in for it: a synthesized cref has no enclosing scope, so it never sees `Minitest` and
# falls through to Ruby's ::Ractor, which is the opposite of what happens in a real file.

module Minitest
  module Ractor
    module LexicalScopeProbe
      # Deliberately unqualified. Resolution walks Minitest::Ractor::LexicalScopeProbe, then
      # Minitest::Ractor, then Minitest — where it finds Minitest::Ractor and stops.
      BARE_RACTOR = Ractor

      # What every file in this gem must write instead.
      QUALIFIED_RACTOR = ::Ractor
    end
  end
end
