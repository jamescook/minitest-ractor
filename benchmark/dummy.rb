# frozen_string_literal: true

# A library that does nothing anybody wants, carefully.
#
# Its only job is to give the benchmark suite something to call that costs a measurable amount
# of CPU and is RACTOR-SAFE, so the numbers measure the pool rather than measuring it falling
# over. Which means, and every one of these is a rule this gem exists to enforce:
#
#   no class or module instance variables, so nothing memoises
#   no class variables and no globals, which a worker may not read even when shareable
#   constants made shareable rather than frozen, since a frozen Array of unfrozen Strings is
#     frozen and still refused
#
# If this file ever stops being Ractor-safe the benchmark will say so loudly, because it runs
# the suite under --ractor as its first act and refuses to time anything with findings in it.
module Dummy
  VOWELS = ::Ractor.make_shareable %w[a e i o u]
  WORDS  = ::Ractor.make_shareable %w[alpha bravo charlie delta echo foxtrot golf hotel]

  # Deliberately the slow recursive one. The benchmark wants CPU burned in Ruby, not an
  # efficient answer.
  def self.fib(number)
    number < 2 ? number : fib(number - 1) + fib(number - 2)
  end

  def self.checksum(text)
    text.each_char.sum(&:ord) % 9973
  end

  def self.vowels_in(text)
    text.each_char.count { |char| VOWELS.include? char }
  end

  def self.shout(text)
    "#{text.upcase}!"
  end

  def self.phrase(seed)
    WORDS.rotate(seed % WORDS.size).first(3).join(" ")
  end
end
