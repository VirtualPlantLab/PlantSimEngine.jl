# [Implementing a model](@id model_implementation_page)

The canonical, executable model-authoring tutorial is now
[Implement a basic model](@ref). Start there for the complete five-argument
kernel contract, direct testing, same-object coupling, and reuse over several
objects.

Before declaring a new abstract process type, use
[New process or new model?](@ref) to determine whether the implementation is a
new scientific process or another hypothesis for an existing process.

Then continue according to the model's needs:

- [Port an existing model](@ref) explains how to keep a scientific kernel
  readable and generic;
- [Model repository layout and tests](@ref) places the process, model,
  documentation, and test levels in a package;
- [Implement Cross-Object Values](@ref) covers `One`, `OptionalOne`,
  `Many`, and `Subtree()`;
- [Coupling models](@ref) distinguishes value coupling, hard calls, and
  explicit adapters;
- [Model compatibility and replacement](@ref) distinguishes process identity
  from drop-in substitutability;
- [Model Traits](@ref) documents environment, timing, output, and scientific
  variable contracts.

!!! compat
    Older versions of this page showed a hard dependency as an abstract model
    type returned directly by `dep(model)`. The current API declares a
    `Call(selector)`, for example
    `(stomata=Call(One(process=:stomatal_conductance)),)`.
