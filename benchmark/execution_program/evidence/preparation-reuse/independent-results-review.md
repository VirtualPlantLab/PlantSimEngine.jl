# Preparation prototype results: independent source/data review

Read-only review of `benchmark/native_downstream/results/preparation-reuse`,
2026-10-30. No Julia or benchmark was executed by this reviewer. Figures below
come from the recorded JSON, not from estimates or earlier PR244 screens.

## Cold first use: one sample per arm

All eight arms have distinct fresh-process PIDs, Julia 1.13.1, apple-m3 and 14
Julia threads. Within each package all four exact scientific digests and work
records match. PB is 2 organs × 2 steps; XP is ONE accelerated growth day, ending
with 11 objects after 3 additions and 16 required streams. The XP forcing has
four rows, but only one day was executed. This is not the four-day warm case.
Experimental loader time is separate (roughly 6.8–7.6 s after Kaimon project
import/startup); filesystem/package precompile caches were not erased.

| Package / arm | Complete s | PSE preparation s | First execution s | Complete allocated GB |
| --- | ---: | ---: | ---: | ---: |
| PB ordinary | 12.9667 | 10.5572 | 0.5828 | 3.8052 |
| PB recipes | 13.3390 | 10.7593 | 0.6273 | 3.8028 |
| PB bounded | 12.5308 | 9.9185 | 0.6181 | 3.6424 |
| PB combined | 12.5329 | 9.9607 | 0.5824 | 3.5933 |
| XP ordinary | 132.6760 | 105.8995 | 15.9651 | 13.3508 |
| XP recipes | 134.5736 | 108.0427 | 16.2827 | 13.4245 |
| XP bounded | 96.4419 | 73.3265 | 12.9861 | 12.0655 |
| XP combined | 97.0220 | 74.1177 | 12.5563 | 12.1389 |

Relative to the ordinary first-use sample, bounded XP has 27.31% lower complete
wall time and 30.76% lower preparation wall time. Combined XP has 26.87% and
30.01% lower times respectively. Recipe-only XP is 1.43% slower complete.
PB bounded/combined are about 3.36%/3.35% lower complete, while recipes alone are
2.87% slower. These are single-sample observations, not repeated cold medians or
confidence bounds. Bounded is the promising compilation candidate; combining
recipes does not improve that result in this screen.

The allocation numbers are cumulative allocated bytes, including compiler/JIT
allocations. They are neither retained memory nor peak process RSS.

### Preparation allocation and compiler counters

| Package / arm | Preparation allocated GB | Reported compilation s | Recompilation s | Compilation / wall |
| --- | ---: | ---: | ---: | ---: |
| PB ordinary | 2.8916 | 10.5444 | 0 | 99.88% |
| PB recipes | 2.9002 | 11.7613 | 1.0164 | counter exceeds wall |
| PB bounded | 2.7393 | 14.1558 | 4.2512 | counter exceeds wall |
| PB combined | 2.6901 | 9.9461 | 0 | 99.85% |
| XP ordinary | 9.4158 | 105.6560 | 0.00836 | 99.77% |
| XP recipes | 9.4800 | 107.7883 | 0.00839 | 99.76% |
| XP bounded | 8.1441 | 73.0876 | 0.00808 | 99.67% |
| XP combined | 8.2086 | 73.8782 | 0.00840 | 99.68% |

Every first execution similarly reports roughly 99.7–99.97% compilation/wall.
Preparation and first execution are dominated by JIT rather than measured
steady scientific computation. Julia's counters are not an exclusive CPU/wall
partition: the raw counters sometimes exceed wall time, and recompilation is
reported as a component of compilation (`base/timing.jl:247–256`). Do not add
recompilation again or interpret the columns as independent percentages summing
to 100. GC also overlaps these compile-heavy phases.

## Repeated warm screens

Ratios below are medians of within-cycle candidate/ordinary ratios, not ratios
of independent medians. Each sample constructs fresh scientific state. PB
medium has FOUR balanced cycles; XP small has THREE. All samples within each
screen have the same expected digest. All use PID54450; image/process provenance
is retained in the source records.

| Fixed task / arm | Paired preparation ratio | Paired execution ratio | Paired complete ratio | Complete wins |
| --- | ---: | ---: | ---: | ---: |
| PB32 × 128 recipes | 1.0560 | 1.0195 | 1.0388 | 1/4 |
| PB32 × 128 bounded | 1.0229 | 1.0058 | 1.0059 | 2/4 |
| PB32 × 128 combined | 1.0712 | 1.0247 | 1.0332 | 0/4 |
| XP4 days recipes | 0.9413 | 0.9907 | 0.9850 | 3/3 |
| XP4 days bounded | 0.9631 | 0.9496 | 1.0157 | 1/3 |
| XP4 days combined | 1.0423 | 0.9938 | 1.0161 | 1/3 |

PB ordinary medians are 3.421 ms preparation, 3.945 ms execution and 7.846 ms
complete. XP ordinary medians are 19.234 ms preparation, 14.191 ms execution and
37.120 ms complete. These are ordinary numerical-executor comparisons; prior
Tight-driver runtime percentages must not be added to them.

Warm complete allocations (ordinary / recipes / bounded / combined):

- PB32 × 128: 4.684 / 4.707 / 4.521 / 4.543 MB.
- XP4 days: 24.185 / 24.260 / 13.568 / 13.643 MB.

Bounded XP thus reduces complete allocation by about 43.90%, preparation
allocation by 49.16%, and execution allocation by 42.54%, despite no consistent
complete-time win in these short warm samples. Recipe-only work slightly
increases allocations. The warm candidate is chiefly an allocation/compilation
result, not a demonstrated general runtime speedup.

The tiny PB2 × 2 three-cycle complete ratios are 1.1082 recipes, 1.0423 bounded,
1.0384 combined; microsecond execution ratios are noisy and not useful speedup
evidence.

### Warm JIT/re-JIT audit

Every timed PB tiny/medium phase has zero compilation, recompilation and GC.
Every XP candidate timed phase has zero compilation/recompilation/GC. The XP
ordinary control has ONE 79.375 microsecond compilation event in cycle2 PSE
preparation; all other control phases have zero JIT, and all XP timed re-JIT/GC
are zero. Therefore do not describe the entire XP warm matrix as absolutely
JIT-free. The event is small relative to ~19 ms preparation.

As a sensitivity check only, dropping the entire affected XP cycle leaves two
pairs: complete ratios 0.9646 recipes, 0.9639 bounded, 1.0249 combined. This small
and changed estimate reinforces the need for cautious timing wording; it is
not a replacement result selected to improve the conclusion.

## Observed reuse and fixed-plan facts

PB32 recipe-only has 3 recipe builds, 93 hits and 96 plain view assemblies;
XP4 has 37 builds, 96 hits and 133 plain assemblies, with 45 ordinary temporal
fallbacks. BOTH normal workloads record zero `plain_preservations` and zero
`bound_interface_reuses`. Consequently there is no measured affected-view
preservation benefit in these workloads. Recipes avoid repeated assembly
analysis; they still allocate each required view and Status identity.

Bounded XP records one scenario plan, five compiled shells (initial + four
growth barriers), and maximum metadata table size61. Existing core already
shares object-independent scenario plans through supported additions. The
2/4-model width checks show bounded scenario maximum tuple width0 versus
ordinary2/4; bounded compiled-type printed length stays2343 bytes and simulation
printed length3605. These are type-string metrics, not compiled machine-code
size or resident memory. Scientific payload types remain concrete.

## Next precompile opportunity

The user's fixed-structure assumption supports preparing declared application
schemas/call-slot blueprints before any target exists. Current symbolic recipes
are learned lazily from actual rows and never invoke Julia `precompile`.
Fixed model types alone do not specify every future canonical Status field
layout, conversion policy, carrier variant, override or environment row type.
A small explicit object-archetype catalogue can supply those missing signatures.

The next bounded proof is one initially targetless worker plus a known singular
child, with declared Float32 status/environment schema. Prepare code/constructor
signatures without running scientific kernels or sharing initialized state;
compare first-birth JIT and total upfront+birth cost for 0→1→2 organs. Add the
empty→typed Many signature as a separate case. Membership, IDs, fresh mutable
cells/default arrays, temporal state, calls/evaluations and sampled environment
values must remain live. See the separate fixed-structure note for the fuller
code-versus-state split; no such eager blueprint is implemented here.
