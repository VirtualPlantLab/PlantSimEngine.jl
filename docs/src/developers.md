# Developer guidelines

This page is intended for people who wish to contribute to PlantSimEngine, and indicates the various parts to bear in mind when adding in new code.

## Working on PlantSimEngine

Instructions are no different than for any other package. Use git to clone the repository [https://github.com/VirtualPlantLab/PlantSimEngine.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl).

When testing your changes, your environement will need to use a command such as `Pkg.develop("PlantSimEngine")` to make use of your code.

We work with VSCode and are most comfortable with that IDE for Julia development. We mostly follow the manual's [Julia style guide](https://docs.julialang.org/en/v1/manual/style-guide/)

Once you've made the necessary checks (see the [Checklist before submitting PRs](@ref) listed below), you’ll need to create your pull request and ask to be added to the contributors if you wish to submit new changes.

This documentation has a [Roadmap](@ref). The list of known issues and related discussions can be found [here](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues). Some are outdated, some are discussions related to potential features, but others are genuine bugs or enhancement suggestions.

Other details and questions can be posted on our issues page, or as part of your Pull Request.

## Quick rundown

### Testing environments

PlantSimEngine has several developer environements:

- `/PlantSimEngine/test`, to check for non-regressions
- `/PlantSimEngine/test/downstream`, whose folder contains a few benchmarks on PlantSimEngine, PlantBioPhysics and XPalm, run as a Github Action, to ensure changes don't cause performance regressions in packages depending on PlantSimEngine. You’ll need to have a version of those packages accessible if you wish to test them locally. Those are distinct from the Github Action that does some integration checks to ensure no unexpected breaking changes occurs.
 `/PlantSimEngine/docs`, to build the documentation. The documentation runs code, and some of the functions' documentation for the API are also tested as `jldoctest` instances

### Running the standard test suite

Simply execute the `/PlantSimEngine/test/runtests.jl` file in the test environment. Note that you'll need to start Julia with multiple threads for the multi-threading tests to successfully run.

You'll also need the companion packages PlantMeteo and MultiScaleTreeGraph, as well as other Julia packages such as DataFrames, CSV, Documenter, Test, Aqua and Tables.

### Downstream tests

With XPalm and PlantBioPhysics properly instantiated, execute the `/PlantSimEngine/test/downstream/test/test-all-benchmarks.jl`. You may need to add some packages for the script to run locally.

### Building the documentation

In the `/PlantSimEngine/docs` environment, run `/PlantSimEngine/docs/make.jl`. It requires a couple of packages that aren't compulsory elsewhere (Documenter, CairoMakie, PlantGeom).

### Editing benchmarks

⁃ If you wish for a branch to be benchmarked after every commit, then you need to declare it in the Github Action for benchmarks's yml file : [https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/.github/workflows/benchmarks_and_downstream.yml](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/.github/workflows/benchmarks_and_downstream.yml) and add your branch to the `on: push:` section.
⁃ You can view benchmarks here: <https://virtualplantlab.github.io/PlantSimEngine.jl/dev/bench/index.html>. They are still somewhat WIP and not yet battle-tested.
⁃ You may occasionally need to update or delete a benchmark, in which case you will need to manually delete it in the **gh-pages** branch, in `dev/bench/index.html`
⁃ The actual benchmark list is located in the `test/downstream` folder.

## Things to keep an eye out for

### Check downstream tests

⁃ If your changes affect the API, then they might affect a package depending on PlantSimEngine. Benchmarks can be a way to check, as some benchmarks run other packages. Otherwise, a specific GitHub action, [https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/.github/workflows/Integration.yml] runs other packages’ test suites. If this action fails, then it is likely some breaking change was introduced that hasn’t been accounted for in the downstream package. If you expected a breaking change and labelled your release as such, there will be no action failure
⁃ Note that those tests don’t build the doc (iirc), so they don’t cover that.
⁃ API changes can also affect downstream packages’ documentation and tests...

### Which documentation pages may be affected by changes

You may impact several specific documentation pages depending on what you changed. Features and API changes affect whatever they might affect, but there are some less obvious ramifications:

⁃ Improving user errors may impact the **Troubleshooting** page.
⁃ Extra features might also expand the **Tips and workarounds** page, as well as the ‘implicit contracts’ page.
⁃ Some experimental features might be worth documenting in the dedicated **API** page, once it's added
⁃ The roadmap "**Planned features**" page needs updating
⁃ Potentially, other pages such as the **Credits** page, **Key Concepts**, etc. If the API makes use of new Julia features or syntax, the **Julia basics** page is probably also worth updating.
⁃ New examples are worth making doctests of.

### Previewing documentation

You can preview generated documentation (assuming it was able to build) relating to your PR (example given with #128) by checking the related link: [https://virtualplantlab.github.io/PlantSimEngine.jl/previews/PR128/](https://virtualplantlab.github.io/PlantSimEngine.jl/previews/PR128/)

## Checklist before submitting PRs

⁃ Ensure your code, uh, works
⁃ Ensure your major changes are covered by some tests, and new features are documented
⁃ Run the PlantSimEngine test suite locally and check errors
⁃ Check on Github which issues it affects, and update/comment those issues, or link them to your Pull Request
⁃ Check which doc page changes are needed (roadmap, … see further up), and update those
⁃ Build the PSE doc and update whatever doc tests were broken
⁃ Push your commit, and let the Github Actions run their course
⁃ Check the 'CI' GitHub action and fix if necessary
⁃ Check downstream and benchmark GitHub actions:
    - If benchmarks tanked, then fix your code. If you need to add/update/delete benchmarks, do so.
    - If you broke an integration/downstream test, you’ll need to investigate it
    - If API changes were made, also check downstream packages’ documentation

It’s probably now safe to request a merge.

### A few extra things worth doing

⁃ You may have some new known issues, some remaining TODOs, document those somewhere, whether in the PR comments or in their own issue, make sure some trace remains
⁃ Finally, update this page and this checklist: If a doc page is added, it may be part of the list of pages you need to keep an eye on. If proper memory allocation tracking and type stability checking is implemented, then that’ll need to be added to the list of things to check prior to a release, etc.

### Other helpful things

⁃ In the `/PlantSimEngine/test` folder, there are a few basic helper functions. One of them outputs vectors of modellists, weather data, and output variables, which are used as a test bank/matrix for some tests, and provides wide coverage. If you wrote new models, new combinations of models, or added some new weather data, it helps to add them to the banks.
⁃ New downstream packages are worth adding to the integration and downstream package registry.
⁃ Unusual corner-cases are worth giving their own unit tests. Newly fixed bugs as well, even if the fix is fairly trivial.

## Noteworthy aspects of the codebase

### Automatic model generation

A specific feature requires generating models on the fly, to enable passing vectors to `Status` objects in multi-scale simulations. There may be more features that wish to generate models.

The solution makes use of a somewhat brittle feature, `eval()`, with some subtleties. You can read more about the related world age problem [here](https://arxiv.org/abs/2010.07516), or [here](https://discourse.julialang.org/t/world-age-problem-explanation/9714/15).

The related file is `model_generation_from_status_vectors.jl`, which has some additional comments.

What is important to bear in mind, is that if you call functions which generate models via `eval()`, you will need to return to top-level scope for those changes to become visible. You can see an example in `tests/helper_functions.jl` with the functions `test_filtered_output_begin` and `test_filtered_output`. The first function calls `modellist_to_mapping`, which creates some models on the fly to convert status vectors between a ModelList and its equivalent pseudo-multiscale mapping. The function is split in two so that it is possible to return to global scope and make the `eval()` changes publicly available. The second function then is able to run the simulations on the mapping with its generated models, and complete the test successfully.

The errors returned by an `eval()`-related issue are very specific, and indicate that a generated model with an UUID suffix does not exist in the Main module, or something along those lines.

There may be a better approach that avoids those pitfalls, but that's what we have for now. Be cautious when calling functions from that file, and make sure to look out for comments indicating a function was split into two.

### Weather/timestep/status combinations

Not all combinations of weather data structure/weather dataset size/status sizes combinations are tested in PlantSimEngine itself. Some are tested in PlantBioPhysics and XPalm. It'd be good to have those structures tested in PSE in the future, but for now it is highly recommended checking those packages' tests when changing the API.

### Test banks

They were briefly mentioned earlier in the page, but the test banks to increase the number of combinations tested for in terms of weather data, modellists/mappings and tracked outputs, could definitely be improved upon.

TODO extra section on memory allocations, type stability etc.
