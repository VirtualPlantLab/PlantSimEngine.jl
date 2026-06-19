# Advanced Time And Environment Configuration

Disambiguate a producer with an explicit selector containing `application`,
`var`, and `within`. Put temporal `policy` and `window` on that input. Configure
environment source renaming and reducers with `Environment`; scenario values
override model-level `meteo_hint` entries.

Use `explain_bindings`, `explain_environment_bindings`, and
`explain_schedule` to inspect the final source, reducer, window, cadence, and
clock origin. All periods that require seconds must be fixed `Dates` periods;
`Month(1)` is intentionally rejected.

