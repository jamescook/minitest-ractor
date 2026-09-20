# minitest-ractor

Runs a Minitest suite in a pool of Ractors instead of a pool of threads, so that any shared
mutable state the tests reach becomes a hard error. The output people come for is the
inventory, not the wall-clock time.

## Language

### The run

**Executor**:
The object Minitest hands work to, one test method at a time. Minitest's own is thread-backed;
ours is Ractor-backed. The name is Minitest's, so we keep it.
_Avoid_: runner, scheduler, dispatcher

**Pool**:
The set of workers an executor owns for the length of a run.
_Avoid_: cluster, group, workers (as a mass noun)

**Worker**:
One Ractor that runs jobs and reports results back. Long-lived: it outlasts any single job.
_Avoid_: thread, process, child, slave

**Job**:
One test method together with the class that defines it — the unit Minitest hands over. A job
is what a worker is given; it is not a file and not a class.
_Avoid_: test, task, unit of work, work item

**Main Ractor**:
Where scheduling happens and where the reporter stays for the whole run. Nothing that lives
here is ever sent to a worker.
_Avoid_: parent, coordinator, host, master

### What a run produces

**Finding**:
One occurrence of the code under test not being Ractor-safe: this test, touching this thing,
got an isolation error. A finding always belongs to exactly one cause.
_Avoid_: failure, error, violation, issue

**Cause**:
The underlying reason a piece of code is not Ractor-safe — a class-level instance variable on
one class, a C extension that never declared itself Ractor-safe. One cause typically produces
many findings, and the inventory is organised by cause because the cause is what somebody
fixes.
_Avoid_: reason, root cause, category, bucket

**Ordinary failure**:
A test that failed or errored for a reason that has nothing to do with Ractors — a wrong
assertion, a genuine bug, a flake. It is not a finding and must never be counted as one or
grouped under a cause. Keeping these apart is what makes the inventory trustworthy.
_Avoid_: real failure, normal failure, unrelated failure

**Inventory**:
The end-of-run report: every cause, each with its findings, ordered so the largest is dealt
with first. The deliverable of a run against an unfamiliar suite.
_Avoid_: report, summary, results, output

**Isolation proof**:
What a fully green run establishes: that no code these tests reached held shared mutable
state. It says nothing about code the suite never ran, and the claim is always stated with
that limit attached.
_Avoid_: safety guarantee, proof of thread safety, certification

### Borrowed from Ruby, used strictly

**Isolation error**:
`Ractor::IsolationError` — Ruby refusing a worker access to something another Ractor can see.
The raw material a finding is made from.

**Shareable**:
Frozen all the way down, so a Ractor may hold it. A shallowly frozen object is not shareable;
the distinction is load-bearing and "frozen" alone never means shareable here.
_Avoid_: frozen, immutable, safe

## Invariants

These hold everywhere in this codebase. Breaking one is a bug, not a trade-off.

- A job crosses into a worker and a result crosses back. Nothing else moves between Ractors.
- The reporter never leaves the main Ractor.
- A worker owns its inbox; only the main Ractor reads the results port. Ports have exactly one
  legal reader.
- A finding is never silently converted into an ordinary failure, and an ordinary failure is
  never counted as a finding.
- The gem's own code holds no shared mutable state. A tool whose premise is "no shared mutable
  state" cannot have any.
- Ruby 4.x only. No compatibility shims for 3.x, ever.
