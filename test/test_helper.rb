# frozen_string_literal: true

require "minitest/autorun"
require "minitest/ractor"

# This gem's own suite runs under plain Minitest — threads, not Ractors. Testing a test runner
# with itself would make a failure in the runner look like a failure in the suite, and there
# would be no way to tell which. `rake test:ractor` exists to run the suite under the pool
# deliberately, once the pool can be trusted.
#
# Fixtures live in test/fixtures/ and are NOT collected by the Rakefile. They are test classes
# holding deliberately unsafe state — input to a test, never a test.
