# Advanced Time And Environment Configuration

Disambiguate a producer with an explicit selector containing `application`,
`var`, and `within`. Put temporal `policy` and `window` on that input. Configure
environment source renaming and reducers with `Environment`; scenario values
override model-level `environment_hint` entries.

Use `Diagnostics.explain_bindings`, `Diagnostics.explain_environment_bindings`, and
`Diagnostics.explain_schedule` to inspect the final source, reducer, window, cadence, and
clock origin. All periods that require seconds must be fixed `Dates` periods;
`Month(1)` is intentionally rejected.

The simulation advances on a fixed base step. `ModelSpec(...; every=...)`
requires a positive integer multiple of that step, including for subsecond
periods. Choose a finer common base step when cadences do not fit: hourly and
90-minute applications need a base step of 30 minutes or finer. The scheduler
does not insert intermediate or adaptive steps automatically.
