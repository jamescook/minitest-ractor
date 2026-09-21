# frozen_string_literal: true

require "rbconfig"

module Minitest
  module Ractor
    # Whose code is this — the project's, a gem's, or Ruby's own?
    #
    # Three things need to know. The inventory should not tell somebody to edit a constant inside
    # a gem they did not write; a finding whose location is inside Minitest needs a better anchor
    # than that before it is printed; and a cause's tier turns entirely on whether the reader can
    # open the file and change it.
    #
    # Asked about a FILE, and separately about a NAMED THING, because those give different
    # answers and only one of them is the right question. See .of_constant.
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

      # Ruby's own globals, measured from a bare process: `ruby --disable-gems -e 'puts
      # global_variables'`. There is no API for asking where a global was defined, and it matters
      # — $LOAD_PATH was the largest single cause in one real suite, and "remove the global
      # variable" is not advice anybody can act on about $LOAD_PATH.
      #
      # A hardcoded list rots, so test_provenance.rb checks it against a bare subprocess. Note
      # "$\\", which is the one entry %w mangles if it is written the obvious way.
      RUBY_GLOBALS = %w[
        $! $" $$ $& $' $* $+ $, $-0 $-F $-I $-W $-a $-d $-i $-l $-p $-v $-w $. $/ $0 $: $; $< $=
        $> $? $@ $DEBUG $FILENAME $LOADED_FEATURES $LOAD_PATH $PROGRAM_NAME $VERBOSE $\\ $_ $`
        $stderr $stdin $stdout $~
      ].freeze

      def self.of(frame)
        path = path_in frame
        return :unknown if path.nil? || path.empty?

        full = File.expand_path path

        return :gem  if under? full, GEM_ROOTS
        return :ruby if under? full, RUBY_ROOTS

        :project
      end

      # What the callers actually want to know: can the person reading this report open the file
      # and change it?
      def self.editable?(frame)
        of(frame) == :project
      end

      # Where a named constant was DEFINED, which is a different question from where the refusal
      # was raised — and the only one worth asking before giving advice about it.
      #
      # MEASURED, and the difference is the whole reason this exists. A worker reading
      # RbConfig::CONFIG from your own lib/catalogue.rb is refused AT YOUR LINE: the backtrace
      # says catalogue.rb and const_source_location says .../rbconfig.rb. Going by the frame, the
      # report would tell you to call make_shareable on a constant belonging to the standard
      # library, which would freeze its strings process-wide on behalf of every other gem loaded.
      #
      # An empty location means the constant was defined in C, so there is no file to open and it
      # is certainly not the project's. Costs 0.3us, so asking once per finding is free even at
      # the 3054 findings one real suite produced.
      #
      # KNOWN LIMIT: this reports where the constant was FIRST assigned, so a module that several
      # libraries reopen is attributed to whichever got there first.
      def self.of_constant(name)
        location = Object.const_source_location name.to_s
        return :unknown if location.nil?
        return :native  if location.empty?

        of location.first
      rescue NameError, TypeError
        :unknown
      end

      # A global has no owner to ask about, so this is a list and not a lookup.
      def self.of_global(name)
        RUBY_GLOBALS.include?(name.to_s) ? :ruby : :project
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
