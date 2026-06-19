# Coupling Values Across Objects

- `One(...)` requires exactly one source.
- `OptionalOne(...)` accepts zero or one.
- `Many(...)` supplies a stable object-ID ordered carrier.

Use `var=` to rename a source and `application=` to distinguish repeated
processes. Homogeneous many-source values use a `RefVector`; heterogeneous
values use an object-aware reference carrier. Inspect both through
`input_carrier`, `input_value`, and `explain_bindings`, not internal fields.
