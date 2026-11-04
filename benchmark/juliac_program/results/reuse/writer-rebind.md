# Rebinding after a distributed writer is born

The regression scene starts with two palms. A background application publishes
`5` on both. At step 2, palm 2 grows a leaf whose distributed output updates
that palm to `9`. The filtered live read starts empty and then sees palm 2
with value `9`. The unfiltered `PreviousTimeStep` reader observes
`[0, 0]`, `[0, 5]` and `[9, 5]` over the three steps. The new producer
has no preceding publication on its first step. The reader uses its original
fallback for that palm until the producer has published. The background
publication remains `5`.

Ordinary PSE includes the existing destinations of newborn writers when it
finds the bindings to refresh. It reuses the existing binding and output
retention rebuild. The typed runtime reselects producers when the committed
origins change and captures initial values for newly eligible destinations
at the growth barrier. Writer validation still checks the declared
`Updates` order.

## Parity

The focused host test passed 32 assertions with and without retained outputs.
The unrelated palm keeps the same ordinary history buffer.
The full prepared reuse suite passed 272 assertions. The ordinary temporal
view and distributed output suites passed 168 assertions.

A fresh Julia 1.13.1 / JuliaC 0.3.12 safe/generic build passed the same
newborn writer trace with both retention settings. The full XPalm binary
matched ordinary PSE for 60 days with retained outputs and 4,160 days with
the original package parameters.
The 60-day comparison covered 246 objects and 122,554 retained values.
The 4,160-day comparison covered 1,190 objects and 27,828 canonical fields.
Both included topology and RNG probes. The 50-hour mixed-cadence CLI output
matched the previous safe binary byte for byte.

| Safe executable | Binary SHA-256 |
| --- | --- |
| Newborn leaf case | `8624a0892e99e954721c5a1c01c99fd5ca82cfff206682d3b61bd63535d21622` |
| Full XPalm and cadence fixture | `72e0a12348bee28c8892eb062be4b5b2e354a0454fe4e0fa83d82421fdcff26f` |

## Timing without growth

Four balanced rounds compare separate Kaimon sessions on the same Mac on AC
power. Each round includes one clocked and one plain run for both revisions
and runtimes. Both use Julia 1.13.1, two compute threads, one GC thread and
no requested output retention. The clocked runs split the 4,160 days using
the verified object-count trace.

| Runtime | 3,675 days without births | 485 days with births | Uninterrupted execution |
| --- | ---: | ---: | ---: |
| Ordinary PSE, reference | 1.045 s | 3.990 s | 5.026 s |
| Ordinary PSE, corrected | 1.015 s | 4.018 s | 5.064 s |
| Prepared, reference | 1.504 s | 1.511 s | 2.955 s |
| Prepared, corrected | 1.523 s | 1.586 s | 3.154 s |

The prepared no-birth median rose by 1.2%. Individual paired changes ranged
from −4.8% to +2.8%, with a paired median of +0.57%. The 250-step case with
768 fixed leaf destinations took 7.533 ms before and 7.527 ms after in the
prepared runtime, with the same 288,880 bytes allocated.

The uninterrupted prepared runs were 6.7% slower in this campaign.
All four pairs favored the reference. Median GC time rose from 0.385 to
0.514 s, and total allocation volume stayed at 3.49 GB. The no-birth
measurements and the fixed-destination case showed no clear slowdown.

The reference is `bd840f10b` and the corrected runtime is `aa67ae2d8`.
The measurements use matched XPalm forcing and original package parameters.
The independently generated ordinary oracles had the same SHA-256. All
48 measured observations passed parity checks and reported zero timed
compilation. The [raw comparison](writer-rebind-4160.json) records the
source hashes, run order, individual timings and daily object counts.
