# frozen_string_literal: true

require "minitest"

# A finding wearing the costume of an ordinary failure, and the reason the classifier may not
# trust a failure's own class.
#
# assert_raises rescues `Exception => e` and calls flunk, so the isolation error never reaches
# the reporter as itself. What arrives is a Minitest::Assertion reading "[ArgumentError]
# exception expected, not ..." — indistinguishable, at a glance, from a test that simply expected
# the wrong exception. Counted as an ordinary failure it would be filtered out of the inventory,
# which is a real finding silently dropped.
#
# It is recoverable because flunk raises from INSIDE that rescue, so Ruby attaches the original
# as #cause. The failure's own backtrace points at assert_raises; only the cause's backtrace
# points here.
class MaskedFixture < Minitest::Test
  # Set while the main Ractor is the only one that exists, so a worker meets an ivar that already
  # holds an unshareable value. That is the refusal Ruby names — "@memo from MaskedFixture" —
  # as opposed to the memoising kind, which fails on the write and names nothing.
  @memo = +"mutable, and set before any worker existed"

  class << self
    attr_reader :memo
  end

  def test_expects_an_argument_error
    assert_raises(ArgumentError) { self.class.memo }
  end

  # The same unsafe ivar reached without a mask over it. One fix repairs both, so the classifier
  # has to put them under one cause — this is the pair that says whether it groups by the thing
  # or by the shape of the failure.
  def test_reads_it_plainly
    refute_empty self.class.memo
  end

  # The same mask over a refusal Ruby does NOT name. Reading an unset ivar is fine — nil is
  # shareable — so this fails on the write, and "can not set instance variables of
  # classes/modules by non-main Ractors" says nothing about which class or which variable.
  #
  # That makes location the only identity such a cause has, which is what makes this pair worth
  # having: with a named cause a wrong origin is invisible, because the name still groups it
  # correctly. Here a wrong origin splits one cause in two.
  def self.memoise
    @memoise ||= +"built inside a worker, if it could be"
  end

  def test_expects_an_argument_error_from_a_write
    assert_raises(ArgumentError) { self.class.memoise }
  end

  def test_writes_it_plainly
    refute_empty self.class.memoise
  end
end

Minitest::Runnable.runnables.delete MaskedFixture
