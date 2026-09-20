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

## Non-goals

- **Not tuned for speed.** It may well be faster: measured here at 6.3× against threads on
  CPU-bound Ruby, where threads gave 1.0×. But that is a side effect, it will not hold for
  IO-bound suites, and no comparison against a fork-based runner has been made. Use this for the
  inventory.
- **Minitest only.** Not RSpec.
- **Not distributed.** One machine, one process.
- **Not a general Ractor toolkit.** The parts here exist to run tests and explain refusals.

## Requirements

Ruby 4.x and Minitest 6. Ractors are still flagged experimental by Ruby, and warn accordingly.

## License

MIT.
