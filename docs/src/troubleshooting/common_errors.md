# Common Errors

A missing-input error means a `Required(T)` input has neither supplied state
nor a producer binding; start with `explain_initialization`. A
plain-input-declaration error means `inputs_` must replace each literal with
`Required(T)` or `Default(value)`. A cardinality error lists selector matches;
correct the scope or choose the intended `OptionalOne`/`Many` multiplicity. An
ambiguity requires an explicit application/object selector.

Duplicate-writer errors require either distinct output routing or an explicit
`Updates` order. Cadence errors require fixed `Dates` periods compatible with
the environment base step. Extend package functions as
`PlantSimEngine.run!(...)`, including the package qualification.
