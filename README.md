# minitest-ractor

Runs your Minitest suite in a pool of Ractors instead of a pool of threads.

A Ractor may not touch mutable state another Ractor can see. Ruby refuses, at the moment of
access, with an error naming what was touched. So a suite that stays green under the pool is a
standing proof that the code those tests reached holds no shared mutable state — and a suite
that does not go green hands you an inventory of every place it does.

The inventory is what you come for.

Ruby 4.x only. There is no 3.x fallback and there will not be one.

## What a green run proves, and what it does not

**Green means no shared mutable state was reached _by these tests_.**

It says nothing about code the suite never ran. A branch no test covers could hold a memoised
class variable and this will never notice. The claim is real but narrow, and it is worth
repeating with the limit attached, because the limit is the half people drop.

## Why not fork

A forked runner gives every process its own copy of memory. Shared mutable state keeps working
there, precisely because nothing is shared — each worker mutates its own copy and never
notices. The bug survives the suite that was meant to find it.

A Ractor has no copy to fall back on. It refuses, and the refusal is the finding.

## Install

```ruby
# Gemfile
gem "minitest-ractor", group: :test
```

## Use

Two things are required, and the second one is easy to miss.

```ruby
# test/test_helper.rb
require "minitest/autorun"
require "minitest/ractor"
```

Minitest only routes a class through the parallel executor once that class has called
`parallelize_me!`. Without it your tests run in the main Ractor and prove nothing:

```ruby
class Minitest::Test
  parallelize_me!          # or per-class, if you would rather go a file at a time
end
```

Then ask for it. Requiring the gem on its own changes nothing:

```bash
ruby -Itest test/some_test.rb --ractor
rake test TESTOPTS="--ractor"
MT_RACTOR=1 rake test
```

## What it tells you

```
============================================================================
minitest-ractor: 4 findings under 2 causes
============================================================================

  1. 3 findings (75%)  ivar_write
     at lib/catalogue.rb:10:in 'Catalogue.index'

     Ruby said:
       can not set instance variables of classes/modules by non-main Ractors

     What to do:
       A worker may not WRITE a class or module instance variable at all,
       shareable value or not, so make_shareable will not help here. Either
       warm it in the main Ractor before the run, or move the state onto the
       instance.

     Reached by:
       CatalogueTest#test_reads_the_memo
       ...and 2 more

  2. 1 finding (25%)  constant: Catalogue::SIZES
     ...

----------------------------------------------------------------------------
1 ordinary failure is not listed above.
```

Findings are grouped **by cause, never by test**. One memoised variable reached by two thousand
tests is one thing to fix and one entry here. A C extension that refuses is one entry however
many places reach it.

A test that failed for reasons that have nothing to do with Ractors is an **ordinary failure**.
Those are counted and never listed. Keeping the two apart is what makes the numbers worth
reading, so the report says so out loud.

The advice differs by cause because the rule does. A class instance variable or a constant
holding a *shareable* value can be read from a worker perfectly well, so `Ractor.make_shareable`
is a genuine one-line fix there. A class variable or a global is refused even when its value is
shareable, so the same advice would send you to freeze something that was never going to help.

## When it refuses to run

Two situations produce a green suite that proved nothing, which is the worst thing this tool
could do — indistinguishable from success, and nobody ever finds out. Both are called out:

- **`MT_CPU=1` with `--ractor`.** `MT_CPU=1` switches Minitest's parallel executor off before
  your test files load, so `parallelize_me!` already did nothing by the time a command-line flag
  can be read. This raises rather than running. Use `MT_RACTOR=1`, which is read early enough.
- **Nothing reached a Ractor.** Usually a missing `parallelize_me!`. The report says `NO PROOF`
  instead of `no findings`.

## Options

| | |
|---|---|
| `--ractor` | Run tests in a pool of Ractors |
| `--no-ractor` | Don't — overrides `MT_RACTOR`, for debugging a finding the normal way |
| `MT_RACTOR=1` | Same as `--ractor`, and the only one that survives `MT_CPU=1` |
| `MT_RACTOR_WORKERS=n` | Pool size. Defaults to the number of processors |

`MT_RACTOR=0`, `false`, `no` and empty all mean no.

## Where this fits

Built for **one machine with a lot of cores** — a laptop or a workstation, where twelve
processors sit mostly idle while Minitest's threads take turns. It runs in a single process and
does not spread work across machines.

If what you want is a suite split across CI workers, that is a different problem, and
[Shopify's ci-queue](https://github.com/Shopify/ci-queue) is the thing to look at. It
distributes tests over many workers using a queue, typically Redis-backed, handing work out as
each worker comes free rather than pre-splitting it, and re-queueing the tests of a worker that
dies. It ships a `minitest-queue` runner, so it fits a Minitest suite directly.

The two are not alternatives and do not compete. ci-queue spreads a suite over machines to
finish sooner; this proves the code those tests reached holds no shared mutable state. Running
ci-queue in CI and this on a laptop is a perfectly sensible arrangement.

## Speed

It is not what this is for, but it is usually faster, and the numbers are worth being precise
about rather than vague.

`benchmark/run.rb` builds a dummy suite and runs the whole thing through each executor in turn.
It checks that every mode passes every test before it times anything, because a mode that fails
fast looks wonderful on a benchmark.

405 tests, CPU-bound, five of them sleeping:

| | iterations/sec | |
|---|---|---|
| serial | 2.5 | |
| threads (12) | 2.6 | 1.05× over serial |
| **ractors (12)** | **18.9** | **7.16× over threads** |

**On this machine**: Apple M2 Max, 12 cores (8 performance, 4 efficiency), 32 GB, macOS 26.5.2,
Ruby 4.0.7. Yours will differ, and so will the same machine under load — an earlier run while
the box was busy gave 4.06× rather than 7.16×. Re-run it rather than trusting anything here.

The number to notice is not really ours: it is that **threads bought 1.05×** across twelve
cores. That is the ceiling on CPU-bound Ruby in one process, and it is why the pool looks good
here. An IO-bound suite would not show this at all, since threads wait perfectly well. No
comparison against a fork-based runner has been made.

## Non-goals

- **Not tuned for speed**, though it is usually faster. See *Speed* below.
- **Minitest only.** Not RSpec.
- **Not distributed.** One machine, one process. See *Where this fits* above.
- **Not a general Ractor toolkit.** The parts here exist to run tests and explain refusals.

## Requirements

Ruby 4.x and Minitest 6. Ractors are still flagged experimental by Ruby, and warn accordingly.

## License

MIT.
