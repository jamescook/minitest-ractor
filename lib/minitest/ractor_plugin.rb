# frozen_string_literal: true

# The plugin file, named the way Minitest.load_plugins expects so that anybody who calls it
# finds us.
#
# MINITEST 6 DOES NOT AUTO-DISCOVER PLUGINS, AND MINITEST 5 DID. Minitest 5 ran
# `load_plugins unless ... MT_NO_PLUGINS` inside Minitest.run, so every installed gem's
# minitest/*_plugin.rb was required on every run on the machine; minitest 6 deleted that line and
# documents load_plugins as "optional, called by user, or require what you want". Since this gem
# is Ruby 4.x only, and Ruby 4.0.7 ships minitest 6, nothing loads this file uninvited.
#
# That has two consequences, and the second is easy to miss:
#
#   1. The old worry is gone. Installing this gem cannot change how anybody else's suite runs,
#      because nothing will load this.
#   2. Nothing appends "ractor" to Minitest.extensions either, and without that entry Minitest
#      never calls the hooks below — the --ractor flag would not even parse. So this file has to
#      register itself, which load_plugins would otherwise have done.
#
# Opt-in is still the design, for a different reason than before: requiring a gem is not the same
# as asking for every test to run in a Ractor today, and somebody who wants it only in CI should
# not have to un-require it.
#
# The decisions all live in Minitest::Ractor::Plugin so that they can be tested without loading
# this.

require_relative "ractor/plugin"

# Guarded because Minitest.load_plugins appends the name itself, after requiring the file, so a
# suite that calls it would otherwise end up with two of us. Harmless if it happens — init checks
# rather than remembers — but there is no reason to leave it.
Minitest.extensions << "ractor" unless Minitest.extensions.include? "ractor"

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
