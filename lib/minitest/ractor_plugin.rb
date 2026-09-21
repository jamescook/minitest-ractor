# frozen_string_literal: true

# The plugin file, named the way Minitest.load_plugins expects, so a suite that calls it finds
# this the same as any other plugin.
#
# DISCOVERY STILL EXISTS IN MINITEST 6, BUT NOTHING CALLS IT FOR YOU. Minitest.load_plugins is
# still there and still requires minitest/*_plugin.rb out of every installed gem; Minitest.run
# simply no longer runs it. So discovery is a thing a suite opts into.
#
# Which means nothing loads this file uninvited — and nothing registers it either. Registration
# is the step load_plugins does after the require, and without it Minitest never calls the hooks
# below: --ractor would not even parse. So this file registers itself, through the API minitest
# documents for exactly this case. register_plugin "does NOT require / load it", which is the
# position of a plugin whose file somebody has already required by name.
#
# Registering only puts the flag on the table. Requiring this gem is still not the same as asking
# for every test to run in a Ractor today, so --ractor and MT_RACTOR remain the only ways in.
#
# The decisions all live in Minitest::Ractor::Plugin so that they can be tested without loading
# this.

require_relative "ractor/plugin"

# Guarded because load_plugins appends the name itself after requiring the file, so a suite that
# calls it as well would end up with two of us. Harmless — init checks rather than remembers —
# but there is no reason to leave it.
Minitest.register_plugin "ractor" unless Minitest.extensions.include? "ractor"

module Minitest
  def self.plugin_ractor_options(opts, options) # :nodoc:
    # --no-ractor comes free with the [no-] form, and earns its place: MT_RACTOR exported in a
    # shell or set on a CI job would otherwise be impossible to switch off for a single run.
    desc = "Run tests in a pool of Ractors and report what is not Ractor-safe"

    opts.on "--[no-]ractor", desc do |wanted|
      options[:ractor] = wanted
    end
  end

  def self.plugin_ractor_init(options) # :nodoc:
    Minitest::Ractor::Plugin.init options
  rescue Minitest::Ractor::ProofNotAttempted => e
    # Raised rather than printed, so that anything driving this as a library can catch it. But a
    # person who has just mistyped a command wants a sentence, not forty frames of minitest
    # internals with the sentence at the top, so at the edge it becomes an ordinary refusal.
    abort "minitest-ractor: #{e.message}"
  end
end

# The only thing that happens merely by this file being loaded, and only when MT_RACTOR says so.
#
# It has to be here rather than in the init hook because this is the last moment BEFORE the test
# files load. Under MT_CPU=1 Minitest builds no parallel executor at all, and parallelize_me!
# quietly does nothing when it finds none — by the time the command line is parsed and --ractor
# is visible, every test class has already decided it is not parallel. An environment variable is
# the only opt-in readable this early.
Minitest::Ractor::Plugin.install_at_load
