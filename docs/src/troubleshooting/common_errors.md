# Common Errors

A missing-input error means neither supplied state, a unique producer, nor an
environment binding exists; start with `explain_initialization`. A cardinality
error lists selector matches; correct the scope or choose the intended
`OptionalOne`/`Many` multiplicity. An ambiguity requires an explicit
application/object selector.

Duplicate-writer errors require either distinct output routing or an explicit
`Updates` order. Cadence errors require fixed `Dates` periods compatible with
the environment base step. Extend package functions as
`PlantSimEngine.run!(...)`, including the package qualification.

