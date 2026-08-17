# Numerical Reliability

Use exact assertions for deliberately exact integer/rational scenarios and
`isapprox` for floating-point scientific results. Splitting a computation
across objects may change reduction order without changing the model.

PlantSimEngine preserves compatible numeric types through parameters, status,
carriers, meteorology, and streams. Avoid forced `Float64` conversion. For long
or ill-conditioned sums, use pairwise or compensated accumulation inside the
scientific model and test its error tolerance explicitly.

