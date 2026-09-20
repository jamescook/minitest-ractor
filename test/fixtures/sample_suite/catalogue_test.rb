# frozen_string_literal: true

# Stands in for somebody else's test file, untouched.
#
# It requires minitest/autorun the way nearly every Ruby test file does, calls parallelize_me!
# nowhere, and has never heard of this gem. Auditing a suite like this is the mode the gem is
# most useful in, and the one that fights Minitest hardest: the autorun hook would run the whole
# thing a second time underneath the audit's own report.

require "minitest/autorun"

class Catalogue
  # The commonest unsafe shape there is. Nothing has populated it, so the first worker to arrive
  # tries to write a class instance variable, which is refused outright.
  def self.index
    @index ||= { "a" => 1 }
  end
end

class CatalogueTest < Minitest::Test
  def test_reads_the_memo
    refute_empty Catalogue.index
  end

  def test_reads_the_memo_again
    assert_equal 1, Catalogue.index["a"]
  end
end
