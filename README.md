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
class variable and this will never notice. The claim is real but narrow, so repeat it with the
limit attached — the limit is the half people drop.

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

## Tests that are about global state

Some tests exist to exercise registration — adding a plugin, a font, a guardrail, a
middleware. Registering usually *defines methods on a class*, which changes the whole process
by design, because that is what the feature is. A worker may not do that. Rewrite the test so
a worker can run it and you are no longer testing the feature.

Those classes say so:

```ruby
class EffectsRegistryTest < Minitest::Test
  runs_on_the_main_ractor!
end
```

They run in the main Ractor, pass normally, and produce no findings. The report counts them as
their own thing, because the scope of the proof depends on it:

```
3 of 5 tests ran in Ractors, and none of them reached shared mutable state. 2 tests used
runs_on_the_main_ractor!.
```

**Watch that second number.** It is the only way to silence a finding, so a suite where it grows
is a suite quietly narrowing what it proves. The switch is per class, not per test: a file about
registration is a whole unit, and a per-test switch would invite marking one test to hide a
problem its siblings share.

## Auditing a suite you have not prepared

The other way in, and the one to reach for when the suite is not yours. No `parallelize_me!`,
no Gemfile entry, no edits of any kind:

```bash
minitest-ractor -I lib -I test test/
```

It loads the test files, runs every test in the pool whether or not anything is marked parallel,
and prints the same inventory. Exit status is 0 when nothing was found, 1 when something was,
and 2 when the audit could not be attempted.

`-I` is usually required, the same way `ruby -I` is: test files tend to `require "test_helper"`,
which is only findable with the target's own directories on the load path.

Doing this means defeating Minitest's autorun hook, which would otherwise run the whole suite a
second time underneath the audit and print its own summary last. Minitest offers no supported
way to stop that, so the runner uses the only lever there is — claiming the hook is already
installed — and keeps that one unsupported line in one file, with a comment saying why.

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
       A worker cannot write a class or module instance variable. This
       applies to all values, shareable or not. Ractor.make_shareable does
       not help. Set the variable in the main Ractor before the run, or move
       the state to the instance.

     Reached by:
       CatalogueTest#test_reads_the_memo
       ...and 2 more

  2. 1 finding (25%)  constant: RbConfig::CONFIG
     first seen at lib/catalogue.rb:18:in 'Catalogue.platform'

     What to do (not your code, so this is a workaround):
       RbConfig::CONFIG belongs to Ruby. You cannot change the definition.
       Do not call Ractor.make_shareable on it: that freezes it for every
       other library in this process. The line that reads it is in your
       project. Make your own copy and read the copy: MINE =
       Ractor.make_shareable(RbConfig::CONFIG, copy: true). The option
       copy: true keeps the original unfrozen.

----------------------------------------------------------------------------
This report does not list 1 ordinary failure.
```

Findings are grouped **by cause, never by test**. One memoised variable reached by two thousand
tests is one thing to fix and one entry here. A C extension that refuses is one entry however
many places reach it.

A test that failed for reasons that have nothing to do with Ractors is an **ordinary failure**.
Those are counted and never listed. Mixing them in would make every number above meaningless,
so the report states which is which.

The advice differs by cause because the rule does. A class instance variable or a constant
holding a *shareable* value can be read from a worker, so `Ractor.make_shareable` is a one-line
fix there. A class variable or a global is refused even when its value is shareable, and the
same advice would send you off to freeze something that could never have helped.

## Fixing what it finds

Findings sort into three tiers, and the tier matters more than the count. **The report says which
tier each cause is in**, on the `What to do` line, so three findings you can fix and three you
cannot are never presented as the same afternoon.

The tier turns on two questions, and asking only the first gets it wrong. *Who owns the thing* —
your code, a gem, Ruby itself — and *who owns the line that reached it*. A worker reading
`RbConfig::CONFIG` from your own file is refused at **your** line, so the backtrace alone would
call it yours and send you off to freeze the standard library.

Everything below was measured on Ruby 4.0.7 by `probes/escape_hatches.rb`.

### Yours to fix

Your own memoised variables, constants and globals. The report names them and says what to do.
The one that surprises people: a class or module instance variable holding a **shareable** value
can be read from a worker, so memoising is not itself the problem — `@thing =
Ractor.make_shareable(...)` at load time is usually the whole fix. A class variable or a global
is refused even when its value is shareable. Freezing those does nothing; they have to go.

Where you need a per-process cache, Ruby has a legal replacement for `@thing ||=`:

```ruby
def self.index
  Ractor.store_if_absent(:index) { build_index }   # per-Ractor, so nothing is shared
end
```

Storage is **per worker**, not per process, so the block runs once in each. Good for a cache,
bad for an expensive one-time build: across twelve workers you pay for it twelve times.

For methods built with `define_method`, whose blocks are Procs and are refused, either use
`Ractor.shareable_proc` or generate real methods with a string `class_eval`. Both work.

### Somebody else's, but you can work around it

A constant in a gem or in the standard library that holds something unshareable —
`RbConfig::CONFIG` is the one most suites will hit. Take a snapshot into a constant of your own:

```ruby
RBCONFIG = Ractor.make_shareable(RbConfig::CONFIG, copy: true)
```

**`copy: true` is the load-bearing part.** Without it `make_shareable` freezes in place, and you
would be freezing RbConfig's strings process-wide on behalf of every other library in the
application. With it, the original is left alone — verified: after taking the snapshot above,
`RbConfig::CONFIG` is still unfrozen and so are its values.

### Nobody can fix from Ruby

- **A C extension that never declared itself Ractor-safe.** Extensions are shut out of Ractors
  by default; the author opts in from C with `rb_ext_ractor_safe(true)`, and nothing in Ruby can
  do it for them. Most of the standard library has — Digest, Zlib, StringIO, Socket, JSON, Date
  and Etc all work from a worker. Ripper and Fiddle have not.
- **A class variable in somebody else's code.** `Minitest::Runnable`'s own `@@runnables` is an
  example. Refused even when shareable, and not yours to change.

The only escape is to not make the call from a worker: do the work in the main Ractor before the
run, or have the worker ask for it and wait.

```ruby
worker = Ractor.new(requests) do |to_main|
  to_main.send [:parse, source]
  Ractor.receive                # the answer comes back through the worker's OWN inbox
end
```

The reply cannot come back through a second `Ractor::Port` created by the main Ractor: a port
has exactly one legal reader, its creator. And the call is no longer parallel, which is the
price of the hatch.

## When it refuses to run

Two situations produce a green suite that proved nothing, which is the worst thing this tool
could do — indistinguishable from success, and nobody ever finds out. Both are called out:

- **`MT_CPU=1` with `--ractor`.** `MT_CPU=1` switches Minitest's parallel executor off before
  your test files load, so `parallelize_me!` already did nothing by the time a command-line flag
  can be read. So it refuses to start. Use `MT_RACTOR=1`, which is read early enough.
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
distributes tests over many workers using a queue, typically Redis-backed. Nothing is pre-split:
work goes out as each worker comes free, and the tests of a worker that dies are re-queued. It
ships a `minitest-queue` runner, so it fits a Minitest suite directly.

The two are not alternatives and do not compete. ci-queue spreads a suite over machines to
finish sooner; this proves the code those tests reached holds no shared mutable state. Running
ci-queue in CI and this on a laptop is a perfectly sensible arrangement.

## Speed

Not what this is for, but it is usually faster, and here are the numbers.

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
the box was busy gave 4.06×. Re-run the benchmark; don't trust anything here.

The number to notice is not really ours: **threads bought 1.05×** across twelve cores. That is
the ceiling on CPU-bound Ruby in one process, and it is why the pool looks good here. An
IO-bound suite would not show this at all, since threads wait perfectly well. No comparison
against a fork-based runner has been made.

## Why not fork

A forked runner gives every process its own copy of memory. Shared mutable state keeps working
there because nothing is shared: each worker mutates its own copy and never notices. The bug
survives the suite that was meant to find it.

A Ractor has no copy to fall back on. It refuses, and the refusal is the finding.

## Non-goals

- **Not tuned for speed**, though it is usually faster. See *Speed* above.
- **Minitest only.** Not RSpec.
- **Not distributed.** One machine, one process. See *Where this fits* above.
- **Not a general Ractor toolkit.** The parts here exist to run tests and explain refusals.

## Requirements

Ruby 4.x and Minitest 6. Ractors are still flagged experimental by Ruby, and warn accordingly.

## License

MIT.
