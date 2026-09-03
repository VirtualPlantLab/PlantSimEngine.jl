# Weather And Environment Inputs

An environment may be a constant named tuple, one tabular row, or regular
multi-row weather. Every row in a timed sequence needs a positive fixed
`duration`; inconsistent base durations and application substeps are rejected.

Use `Environment(sources=...)` to map model-facing environment names to
provider columns. Values retain compatible user numeric types. Spatial
providers implement the same model-facing contract and refresh bindings after
object movement or geometry changes.
