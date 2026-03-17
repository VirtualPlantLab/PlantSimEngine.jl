# Developer Guidelines

This page is for contributors working on PlantSimEngine itself. It focuses on
the local development workflow, the checks worth running before opening a pull
request, and a few implementation details that are easy to miss.

## Working on PlantSimEngine

Clone the repository from
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl) and develop
against a checked-out local copy, typically through `Pkg.develop(path="...")`.

We mostly follow the Julia manual's
[style guide](https://docs.julialang.org/en/v1/manual/style-guide/). Questions,
bug reports, and design discussions should go through
[GitHub issues](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues) or
the related pull request.

The [Roadmap](@ref) summarizes longer-term work that is not yet complete.

## Local environments

PlantSimEngine currently has three main local environments:

- `test/` for the package test suite and doctests run from `test/runtests.jl`;
- `docs/` for the Documenter build;
- `benchmark/` for benchmark scripts used to compare performance locally.

## Running checks locally

### Main test suite

Run the standard test suite from the repository root:

```julia
julia --project=test test/runtests.jl
```

Some tests exercise threaded execution, so it is worth running them with more
than one Julia thread when validating parallel behavior.

### Documentation

Build the documentation from the repository root with:

```julia
julia --project=docs docs/make.jl
```

The docs environment includes the extra packages needed for examples and API
documentation, such as `Documenter`, `CairoMakie`, `PlantMeteo`, and
`MultiScaleTreeGraph`.

### Benchmarks

Benchmark scripts live in `benchmark/`. They are useful when a change may alter
runtime characteristics, but they are not a substitute for the main test suite
or downstream integration checks.

## CI workflows

The repository currently relies on these GitHub Actions workflows:

- `CI.yml` for the main test matrix, docs build, and coverage;
- `Integration.yml` for downstream checks against packages that depend on
  PlantSimEngine;
- `Benchmarks.yml` for pull-request benchmark runs;
- `register.yml` and `TagBot.yml` for release automation.

If a change affects public APIs or execution behavior, check both `CI` and
`Integration` before merging. Benchmark results are useful for regressions, but
should be interpreted alongside the test results.

## Documentation impact

Changes in PlantSimEngine often require documentation updates beyond the page you
were editing.

- User-facing errors often require updates to the troubleshooting pages.
- New examples should ideally become doctests or rendered examples.
- API or behavior changes may require updates to the roadmap, migration notes,
  and example pages.
- If a feature remains experimental, say so clearly in the docs instead of
  letting examples imply stable support.

## Pull request checklist

- Make sure the change is covered by tests.
- Run the main test suite locally.
- Build the documentation locally if docstrings, examples, or APIs changed.
- Review the affected docs pages and update them in the same pull request.
- Check GitHub Actions after pushing.
- If the change is breaking or deprecates an old path, document the migration
  path before merging.

## Implementation notes

### Generated models from status vectors

Some multiscale helpers turn status vectors into internal runtime models so that
they can be used in mapping-based simulations. The implementation is kept
deliberately data-driven to avoid top-level `eval()` and world-age issues.

The relevant code lives in `src/mtg/mapping/model_generation_from_status_vectors.jl`.
If you touch that area, preserve the ability to generate the mapping and build a
`GraphSimulation` within the same function scope.

### Coverage gaps to keep in mind

Not every combination of weather structure, status shape, mapping layout, and
downstream usage is covered directly in PlantSimEngine. When changing the public
API or runtime semantics, treat downstream integration results as part of the
validation surface, not as optional extra signal.
