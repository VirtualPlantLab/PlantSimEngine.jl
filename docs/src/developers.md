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

The current public runtime is sequential. Running with multiple Julia threads
does not enable a parallel Composite model executor; parallel execution remains roadmap
work and requires dedicated correctness tests before it becomes public.

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

## Graph Viewer Frontend

The static viewer and HTTP editor share the React application under
`frontend/`. PlantSimEngine releases include the production bundle in
`frontend/dist`, because Julia package installations do not run Node or Vite.
The content hash in asset filenames is intentional: it prevents browsers and
documentation hosts from reusing stale JavaScript after a release.

Install the frontend development dependencies from the repository root:

```sh
cd frontend
npm ci
```

Run the fast checks while developing:

```sh
npm run typecheck
npm test
```

Build the production assets after changing TypeScript, CSS, or frontend
dependencies:

```sh
npm run build
```

Commit the resulting `frontend/dist` changes together with the source changes.
Do not commit `frontend/node_modules`, Playwright reports, screenshots, videos,
or local test output.

The end-to-end suite starts a real Julia `edit_graph` session and controls it
with Chromium:

```sh
npx playwright install chromium
npm run test:e2e
```

Use `npm run test:e2e:ui` for a headed local debugging session. The tests use
stable `data-testid` attributes for commands and confirm mutations through the
Julia `/state` endpoint. Avoid assertions against generated CSS classes or
implementing PlantSimEngine selector semantics in TypeScript.

Core graph DTO and edit tests live in `test/test-model-graph-view.jl`.
HTTP-extension tests live in `test/test-model-graph-editor-extension.jl`.
When changing the graph schema, update those Julia tests, frontend types, unit
tests, Playwright scenarios, and the committed production bundle in the same
change.

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

### Coverage gaps to keep in mind

Not every combination of weather structure, status shape, mapping layout, and
downstream usage is covered directly in PlantSimEngine. When changing the public
API or runtime semantics, treat downstream integration results as part of the
validation surface, not as optional extra signal.
