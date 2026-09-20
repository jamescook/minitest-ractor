# frozen_string_literal: true

require "rbconfig"

module Minitest
  module Ractor
    # Whose code is this file — the project's, a gem's, or Ruby's own?
    #
    # Two things need to know. The inventory should not tell somebody to edit a constant inside
    # a gem they did not write, and a finding whose location is inside Minitest needs a better
    # anchor than that before it is printed.
    #
    # THE RULE IS DELIBERATELY NEGATIVE: everything is the project's unless it is demonstrably
    # somewhere else. Guessing "not yours" wrongly is the damaging direction — it downgrades a
    # finding somebody could have fixed into one they are told to work around — while guessing
    # "yours" wrongly only means the advice is more hopeful than it should be.
    #
    # KNOWN LIMIT, and it follows from that choice. A gem checked out elsewhere and loaded with
    # Bundler's `path:` or `git:` sits under none of these roots, so it reads as the project's.
    # That is the better answer more often than not — you can edit a checkout — but it is a
    # guess, and worth knowing before trusting a tier on something vendored.
    module Provenance
      # Computed once at load. These do not move during a run, and asking Gem for its paths on
      # every backtrace frame of every finding would be thousands of calls for one answer.
      GEM_ROOTS = ([Gem.default_dir] + Gem.path).compact.map do |dir|
        File.expand_path dir
      end.uniq.freeze

      RUBY_ROOTS = %w[rubylibdir archdir libdir].filter_map do |key|
        RbConfig::CONFIG[key]&.then { |dir| File.expand_path dir }
      end.uniq.freeze

      # "path.rb:12:in 'Thing#method'" — everything up to the line number.
      FRAME = /\A(?<path>.+?):\d+(?::in\b.*)?\z/

      def self.of(frame)
        path = path_in frame
        return :unknown if path.nil? || path.empty?

        full = File.expand_path path

        return :gem  if under? full, GEM_ROOTS
        return :ruby if under? full, RUBY_ROOTS

        :project
      end

      # What both callers actually want to know: can the person reading this report open the
      # file and change it?
      def self.editable?(frame)
        of(frame) == :project
      end

      def self.path_in(frame)
        return nil if frame.nil?

        frame.to_s.then { |text| FRAME.match(text)&.[](:path) || text }
      end

      def self.under?(path, roots)
        roots.any? { |root| path.start_with? "#{root}/" }
      end
      private_class_method :path_in, :under?
    end
  end
end
