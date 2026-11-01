# First original XPalm case (in qualification)

The pinned XPalm revision is `5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd`.
No XPalm source is modified. The admitted subgraph uses its original
DailyDegreeDays, FTSW and RootGrowthFTSW methods. The FTSW model's existing `dep`
declaration supplies the call. Only thermal time and soil water are scheduled;
FTSW decides when to run the root model, with live parent state and publication.

This case tests root-depth growth and addition of independent soil columns by
the host at timestep boundaries. It does not yet implement PhytomerEmission,
MTG node creation, multiple organ categories, initializers or a whole palm.
The smallest original phytomer-emission neighborhood identified by source audit
has eleven applications, five targeted calls and two newborn initializers.
That path needs multiple cohort schemas and MTG lifecycle support; it must not
be represented as covered by independent-column growth.

Current Julia-level checks: 627 assertions over fourteen XPalm cases, comparing
all canonical state variables and every original output's full publication
series, plus varied weather/parameters/IDs/populations and births from zero.
The existing local-fixture matrix and generic nested-call checks also pass.
Native build qualification is tracked separately below when available.
