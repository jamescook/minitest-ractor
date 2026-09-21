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

      # The tier rides on the advice, because that is where it changes what somebody does next.
      # Three findings you can fix and three you cannot are the same number and a different
      # afternoon, and a report that does not say which is which sends people to edit gems.
      TIER_LABELS = {
        yours: "What to do:",
        theirs: "What to do (not your code, so this is a workaround):",
        nobodys: "What to do (nothing here can be fixed from Ruby):"
      }.freeze

      attr_reader :findings, :ordinary_failures, :total, :reached_workers, :opted_out

      def self.from(results, limit: DEFAULT_LIMIT)
        findings = []
        ordinary = 0

        results.each do |result|
          finding = Classifier.classify result
          next findings << finding if finding

          ordinary += 1 if failed?(result)
        end

        new findings:, ordinary_failures: ordinary, total: results.size, limit:,
            reached_workers: results.count { |result| in_a_worker? result },
            opted_out: results.count { |result| opted_out? result }
      end

      # Said runs_on_the_main_ractor!. A THIRD CATEGORY, next to findings and ordinary failures,
      # and it has to be counted separately for the same reason those two do: it changes what the
      # run proves. A test that asked not to go is not a test that failed to get there.
      def self.opted_out?(result)
        result.respond_to?(:metadata) && result.metadata[:minitest_ractor_opted_out] == true
      end
      private_class_method :opted_out?

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
                     reached_workers: 0, opted_out: 0)
        @findings          = findings
        @ordinary_failures = ordinary_failures
        @total             = total
        @limit             = limit
        @reached_workers   = reached_workers
        @opted_out         = opted_out
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
         *indent(TIER_LABELS.fetch(cause.tier, TIER_LABELS[:yours]), cause.remedy),
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
        where += "  (#{Provenance.of(cause.origin)} code, which you cannot change)" unless
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
         *wrap("Each finding below is one refusal. Ruby refused to let a worker touch state " \
               "that another Ractor can see. This report groups the findings by cause. One " \
               "cause is one change, even when many tests reached it.", WIDTH)]
      end

      # Printed every run, because it IS the scope of the proof. A suite of mixed parallel and
      # serial classes is perfectly legitimate, so a partial number is not a shortfall to
      # apologise for — it is the honest answer to "what did this cover", which until now was a
      # limitation stated in prose and never in figures.
      # The scope of the proof, in figures, every run.
      #
      # The opt-outs get their own sentence rather than being folded into the shortfall. A test
      # that said runs_on_the_main_ractor! narrowed the proof ON PURPOSE, and reading that as the
      # same thing as a test the pool failed to reach would hide the one number worth watching:
      # if it grows, somebody is silencing findings with it.
      def coverage(clause = nil)
        line = "#{@reached_workers} of #{count(@total, 'test')} ran in Ractors#{clause}."
        line += " #{count(@opted_out, 'test')} used runs_on_the_main_ractor!." if
          @opted_out.positive?

        unaccounted = @total - @reached_workers - @opted_out
        return wrap(line, WIDTH) unless unaccounted.positive?

        wrap("#{line} The other #{count(unaccounted, 'test')} ran in the main Ractor and did " \
             "not ask to. This report proves nothing about that code.", WIDTH)
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

        ["",
         "-" * WIDTH,
         *wrap("This report does not list #{count(@ordinary_failures, 'ordinary failure')}. An " \
               "ordinary failure is a test that failed for a reason that is not related to " \
               "Ractors. The report counts these failures here only. It does not add them to " \
               "the findings above.", WIDTH)]
      end

      # A green run is the product, so it is worth saying properly — including the limit, which
      # is the part people drop when they repeat it.
      def nothing_found
        return nothing_attempted if proved_nothing?

        [*heading("no findings"),
         "",
         *coverage(", and none of them reached shared mutable state"),
         "",
         *wrap("The proof is limited. It applies only to the code that THESE TESTS REACHED. It " \
               "says nothing about code that they did not reach.", WIDTH),
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
         *wrap("#{count(@total, 'test')} ran. No test left the main Ractor. This run tested no " \
               "code for isolation. THIS IS NOT A PASS.", WIDTH),
         "",
         *wrap(why_nothing_ran, WIDTH),
         *parallelize_me_snippet,
         *ordinary_note].join("\n")
      end

      def parallelize_me_snippet
        return [] if everything_opted_out?

        ["", "    class Minitest::Test", "      parallelize_me!", "    end"]
      end

      def everything_opted_out?
        @opted_out.positive? && @opted_out == @total
      end

      # Two quite different situations, and telling somebody to add parallelize_me! when every
      # class already said runs_on_the_main_ractor! would send them to do the one thing that
      # cannot help.
      def why_nothing_ran
        if everything_opted_out?
          "Every test class used runs_on_the_main_ractor!. A test about global state can do " \
            "this correctly. But a suite where all classes do this proves nothing. Examine the " \
            "opt-outs, not this report."
        else
          "Minitest sends a class to the parallel executor only after the class calls " \
            "parallelize_me!. Add parallelize_me! to each test class that you want to cover. " \
            "To cover every class, add it to Minitest::Test:"
        end
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
