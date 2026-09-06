# The choice of using Julia

PlantSimEngine uses Julia so that researchers can write process equations,
assemble simulations, inspect results, and improve computational performance
in the same language. This supports the model-development workflow described
in [Why PlantSimEngine?](why_plantsimengine.md).

## Keep equations and their implementation close

A process model contains a Julia function whose inputs, state, and parameters are
explicit. You can read its calculations, call it directly in a small test,
and reuse it in a larger simulation. Optional
[Unicode names](https://docs.julialang.org/en/v1/manual/unicode-input/) can keep
symbols close to the notation in a paper, while descriptive names make their
meaning clear. The [model-author tutorial](../journeys/modelers/basic_model.md)
shows a complete example.

Julia also lets numerical code work with different compatible value types.
For example, a model can preserve `Float32` values or carry uncertainty through
an optional numerical package when its operations support those types. See
[numerical reliability](../guides/data/numerical_reliability.md) for the
requirements and examples.

## Prototype, measure, and improve in one language

You can begin with a readable implementation and use Julia's timing,
profiling, and type-inspection tools to find where optimization is useful.
Keeping the model in Julia makes it possible to maintain the same tests while
improving its implementation.

Performance depends on the algorithm, how data are stored, how much memory
must be created, and how much work the simulation requests. The first run can
also take longer while Julia prepares the code for execution. Measure that
first run separately from repeated runs.
Julia's [performance guide](https://docs.julialang.org/en/v1/manual/performance-tips/)
explains these distinctions. PlantSimEngine's
[benchmarking guidance](../developers.md) adds the costs of scenario
initialization, structural updates, and output collection.

## Share the software environment with the experiment

Julia's package manager supports a separate environment for each project.
Its `Project.toml` lists the packages the project needs, and its `Manifest.toml`
records the exact versions used. Sharing these files, the Julia version, model code, and
input data helps others recreate an experiment. See the official
[environment guide](https://pkgdocs.julialang.org/v1/environments/) and
[PlantSimEngine installation](../prerequisites/installing_plantsimengine.md).

Learning Julia still takes time, especially its type system and package
workflow. Start with [Julia basics](../prerequisites/julia_basics.md), then
[run one coupled simulation](../journeys/users/one_object.md). You can learn
the model-author tools when your research requires a new equation or process.
