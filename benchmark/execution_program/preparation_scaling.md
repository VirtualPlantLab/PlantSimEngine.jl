# Bounded graph and typed preparation: gradual downstream qualification

Work in progress. The existing opt-in preparation candidates are unchanged;
this round extends independent qualification to longer single-palm XPalm
trajectories, more PlantBiophysics objects and fresh-worker first use.
Ordinary scientific kernels, canonical references and execution remain the
control. No default is changed.

## Current checked stages

Small gates pass for both XPalm parameter profiles and 2/4-object PB. Per-step
full state/history/RNG/types/reference/carrier/work gates then pass for 12/32/64
XPalm days and 16/32/128 PB objects. Accelerated XP32 reaches 104 objects in one
scene; package-default XP32 reaches 17. Larger stages are explicitly gated by
preceding correctness and measured cost, not aggregates of tiny replicas.

The accelerated profile changes the two phyllochron speeds to 0.2; the
package-default profile changes no scientific parameter. Both explicitly use
initiation age zero and architecture disabled. They are separate cohorts,
with actual object counts reported. Default two-day XP produces no newborns
and receives no newborn-optimization credit.

## Initial warm observations

Ratios are medians of paired per-cycle ratios against ordinary A; lower is
better. Four balanced cycles use independent fresh scenarios and ordinary
A/A controls. Preparation and execution are measured separately; complete
cost includes construction, enablement, normal preparation and execution.

| Case | Combined preparation | Combined execution | Combined complete | Ordinary B complete |
| --- | ---: | ---: | ---: | ---: |
| PB, 16 objects × 4 steps | 0.797 | 1.092 | 0.818 | 0.983 |
| PB, 32 objects × 8 steps | 0.772 | 1.092 | 0.816 | 1.007 |
| XP, 12 accelerated days, 44 final objects | 0.707 | 0.832 | 0.819 | 0.981 |
| XP, 32 accelerated days, 104 final objects | 0.696 | 0.865 | 0.848 | 0.946 |

PB's current saving is preparation, not scientific execution. Graph preparation
alone is approximately neutral on the small three-application PB fixture. XP
shows a combined-policy runtime benefit, but the additional typed-boundary
benefit must be compared with graph alone, not inferred from the ordinary
comparison. The identical controls expose noise/order effects; one tiny XP32
control compilation event is retained.

The 64-day/default and larger-PB screens, fresh-worker cold pilots and frozen
evidence summary remain pending. Cold import/driver/registration costs will be
separate from model construction/preparation/first step/remainder, with normal
disk caches retained and one fresh independent warm companion. A cold-driver
keyword-specialization annotation error was caught and corrected by a load-only
check before any cold scientific timing; the failed source/receipt are retained.
No cold, million-organ, peak-RSS or full-regression qualification is claimed yet.
