# frozen_string_literal: true

require_relative "classifier"
require_relative "provenance"

module Minitest
  module Ractor
    # The end-of-run report: every cause, each with the findings that belong to it, largest
    # first. The deliverable of a run against an unfamiliar suite.
    #
    # ORGANISED BY CAUSE BECAUSE THE CAUSE IS WHAT SOMEBODY FIXES. A C extension that never
    # declared itself Ractor-safe is one thing to fix however many tests trip over it, and a
    # report that prints it once per test is the wall of identical failures this exists to
    # replace. Against a real suite, 3054 findings turned out to be 85 causes, and one of them
    # accounted for four fifths of everything.
    #
    # ORDINARY FAILURES ARE COUNTED BUT NEVER LISTED. A test can fail for reasons that have
    # nothing to do with Ractors, and mixing those in would make every number here untrustworthy.
    # They are reported as a count, separately, so that the separation is visible rather than
    # assumed.
    class Inventory
      WIDTH = 92
      DEFAULT_LIMIT = 20
      EXAMPLES = 3

      attr_reader :findings, :ordinary_failures, :total, :reached_workers

      def self.from(results, limit: DEFAULT_LIMIT)
        findings = []
        ordinary = 0

        results.each do |result|
          finding = Classifier.classify result
          next findings << finding if finding

          ordinary += 1 if failed?(result)
        end

        new findings:, ordinary_failures: ordinary, total: results.size, limit:,
            reached_workers: results.count { |result| in_a_worker? result }
      end

      # The executor stamps every result with the worker that ran it, so an unstamped result is
      # one that never left the main Ractor. Worth counting, because "nothing failed" and
      # "nothing was tried" look identical from the outside and only one of them is a proof.
      def self.in_a_worker?(result)
        result.respond_to?(:metadata) && !result.metadata[:minitest_ractor_worker].nil?
      end
      private_class_method :in_a_worker?

      # Skips are not failures, and a passing result has nothing to answer for. Anything that
      # reached here without being classified as a finding and still did not pass is somebody's
      # test being wrong, which is not this tool's business beyond saying how many there were.
      def self.failed?(result)
        result.respond_to?(:passed?) && !result.passed? && !result.skipped?
      end
      private_class_method :failed?

      def initialize(findings:, ordinary_failures: 0, total: 0, limit: DEFAULT_LIMIT,
                     reached_workers: 0)
        @findings          = findings
        @ordinary_failures = ordinary_failures
        @total             = total
        @limit             = limit
        @reached_workers   = reached_workers
      end

      # Causes, each with its findings, commonest first.
      def causes
        @causes ||= @findings.group_by(&:cause).sort_by { |_, found| -found.size }
      end

      def empty?
        @findings.empty?
      end

      # Tests ran and none of them left the main Ractor, so nothing here was checked for
      # isolation. Distinct from a green run in the only way that matters, and the reason the
      # reporter fails the build: a proof that was never attempted must not read as one that
      # succeeded.
      def proved_nothing?
        @reached_workers.zero? && @total.positive?
      end

      def to_s
        return nothing_found if empty?

        [heading("#{count(@findings.size, 'finding')} under #{count(causes.size, 'cause')}"),
         *preamble,
         *causes.first(@limit).each_with_index.map { |(cause, found), i| section(cause, found, i) },
         *elided,
         *ordinary_note].join("\n")
      end

      private

      def section(cause, found, index)
        share = (found.size * 100.0 / @findings.size).round

        [+"",
         format("%<n>3d. %<many>s (%<share>d%%)  %<what>s",
                n: index + 1, many: count(found.size, "finding"), share:, what: headline(cause)),
         "     #{locator(cause)}",
         "",
         *indent("Ruby said:", cause.message.to_s.lines.first.to_s.strip),
         "",
         *indent("What to do:", cause.remedy),
         "",
         *reached_by(found)].join("\n")
      end

      # Lead with the thing Ruby named, because that is what somebody greps for and what they
      # will edit. The kind alone ("ivar_read") says what sort of mistake it is and not where.
      def headline(cause)
        cause.named? ? "#{cause.kind}: #{cause.subject}" : cause.kind.to_s
      end

      # For a named cause the location is only where it happened to be noticed first — the same
      # ivar reached from thirty places is still one cause — so the wording must not imply the
      # fix lives at that line. When Ruby named nothing, the location IS the identity.
      def locator(cause)
        where = relative(cause.origin)
        where += "  (inside #{Provenance.of(cause.origin)} code, not yours)" unless
          Provenance.editable?(cause.origin)

        cause.named? ? "first seen at #{where}" : "at #{where}"
      end

      # Names each test, and where it is written when the cause's own location is no use to
      # anybody — a refusal reported inside minitest is a true location and an unhelpful one, so
      # the tests get to say where they actually live.
      def reached_by(found)
        anchor = !Provenance.editable?(found.first.origin)

        shown = found.first(EXAMPLES).map do |finding|
          written = " — written at #{relative(finding.defined_at)}" if anchor && finding.defined_at
          "       #{finding.location}#{written}"
        end
        rest = found.size - shown.size

        ["     Reached by:", *shown, *(rest.positive? ? ["       ...and #{rest} more"] : [])]
      end

      def indent(label, text)
        ["     #{label}", *wrap(text, WIDTH - 7).map { |line| "       #{line}" }]
      end

      # A cause's own words can be long, and the remedies are deliberately sentences rather than
      # slogans, so they have to fold rather than run off the terminal.
      def wrap(text, width)
        text.to_s.split.each_with_object([+""]) do |word, lines|
          if lines.last.empty?
            lines.last << word
          elsif lines.last.length + 1 + word.length <= width
            lines.last << " " << word
          else
            lines << +word
          end
        end
      end

      def heading(title)
        ["=" * WIDTH, "minitest-ractor: #{title}", "=" * WIDTH]
      end

      def preamble
        ["",
         *coverage,
         "",
         *wrap("Every finding below is Ruby refusing a worker access to state another Ractor " \
               "can see. They are grouped by cause, because the cause is what you fix: one " \
               "cause is one change, however many tests tripped over it.", WIDTH)]
      end

      # Printed every run, because it IS the scope of the proof. A suite of mixed parallel and
      # serial classes is perfectly legitimate, so a partial number is not a shortfall to
      # apologise for — it is the honest answer to "what did this cover", which until now was a
      # limitation stated in prose and never in figures.
      def coverage(clause = nil)
        line = "#{@reached_workers} of #{count(@total, 'test')} ran in Ractors#{clause}."
        return wrap(line, WIDTH) if @reached_workers == @total

        wrap("#{line} The proof covers those #{@reached_workers} and says nothing about the " \
             "rest, which ran in the main Ractor.", WIDTH)
      end

      # The rest, one line each, rather than a count of things withheld.
      #
      # A suite nobody has tidied produces causes by the dozen — 84 in the run this was built
      # against — and printing all of them in full is 800 lines nobody reads, while printing a
      # number and stopping loses the very thing the inventory is for. So the tail is still
      # every cause, just briefly.
      def elided
        rest = causes.drop(@limit)
        return [] if rest.empty?

        ["",
         "     ...and #{count(rest.size, 'further cause')}, in brief:",
         "",
         *rest.map do |cause, found|
           format("     %<n>6d  %<what>s", n: found.size, what: brief(cause))
         end]
      end

      # A kind on its own says nothing when Ruby named nothing, so an unnamed cause keeps its
      # location even here.
      def brief(cause)
        cause.named? ? headline(cause) : "#{cause.kind} at #{relative(cause.origin)}"
      end

      # Stated as a count and never as a list. The separation between a finding and an ordinary
      # failure is the thing that makes the rest of this report worth reading, so it is said out
      # loud rather than left to be inferred from the numbers not adding up.
      def ordinary_note
        return [] if @ordinary_failures.zero?

        verb = @ordinary_failures == 1 ? "is" : "are"

        ["",
         "-" * WIDTH,
         *wrap("#{count(@ordinary_failures, 'ordinary failure')} #{verb} not listed above. A " \
               "test that failed for reasons unrelated to Ractors is counted here and nowhere " \
               "else: mixing those in with findings would make every number above worthless.",
               WIDTH)]
      end

      # A green run is the product, so it is worth saying properly — including the limit, which
      # is the part people drop when they repeat it.
      def nothing_found
        return nothing_attempted if proved_nothing?

        [*heading("no findings"),
         "",
         *coverage(", and none of them reached shared mutable state"),
         "",
         *wrap("The proof is narrow on purpose. It covers the code THESE TESTS REACHED and says " \
               "nothing about code they did not.", WIDTH),
         *ordinary_note].join("\n")
      end

      # Nothing failed and nothing was attempted look identical from the outside, and only one of
      # them is a proof. Claiming the first while meaning the second is the worst thing this tool
      # can do: it is indistinguishable from success and nobody ever finds out.
      #
      # The usual cause is a suite whose classes never called parallelize_me!. Minitest only
      # routes a class through the parallel executor once it has, so without it every test runs
      # in the main Ractor and passes for exactly the reason it always did.
      def nothing_attempted
        [*heading("NO PROOF — nothing reached a Ractor"),
         "",
         *wrap("#{count(@total, 'test')} ran and not one of them left the main Ractor, so " \
               "nothing here was tested for isolation. This is not a pass.", WIDTH),
         "",
         *wrap("Minitest only routes a class through the parallel executor once it has called " \
               "parallelize_me!. Add it to the test classes you want covered, or to " \
               "Minitest::Test itself to cover everything:", WIDTH),
         "",
         "    class Minitest::Test",
         "      parallelize_me!",
         "    end",
         *ordinary_note].join("\n")
      end

      # Absolute paths are how a backtrace arrives and not how anybody reads one.
      def relative(origin)
        return "(no location)" if origin.nil?

        origin.sub("#{Dir.pwd}/", "")
      end

      def count(number, noun)
        "#{number} #{noun}#{'s' unless number == 1}"
      end
    end
  end
end
