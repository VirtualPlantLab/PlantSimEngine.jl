using PlantSimEngine
using PlantMeteo
using DataFrames, CSV
using Documenter
using Bonito
using CairoMakie
using PlantSimEngine.Examples

include(joinpath(@__DIR__, "model_source.jl"))
include(joinpath(@__DIR__, "bonito_rendering.jl"))

function build_model_graph_example()
    output_dir = joinpath(@__DIR__, "src", "assets")
    mkpath(output_dir)
    model = PlantSimEngine.CompositeModel(
        ToyDegreeDaysCumulModel(),
        ToyLAIModel(),
        Beer(0.6);
        status=(TT=12.0,),
        id=:plant,
        scale=:Plant,
        kind=:plant,
    )
    GraphEditor.write_model_graph_view(
        joinpath(output_dir, "model_graph_example.html"),
        model,
    )
end

build_model_graph_example()

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames, CSV, CairoMakie); recursive=true)

home = (
    name="PlantSimEngine.jl",
    text="Build plant simulations from connected process models",
    tagline="Combine models of growth and plant–environment interactions in Julia, " *
            "from crop canopies to individual plants and organs.",
    image="assets/logo.png",
    actions=[
        (text="Couple existing models", link="journeys/users/one_object.html", theme="brand"),
        (text="Write a process model", link="journeys/modelers/basic_model.html", theme="alt"),
    ],
    features=[
        (
            title="Crop and canopy models",
            details="Connect phenology, canopy development and resource capture without representing every organ.",
            link="journeys/users/one_object.html",
        ),
        (
            title="Functional–structural models",
            details="Apply processes to individual organs and connect their exchanges as plants grow.",
            link="journeys/users/one_plant.html",
        ),
        (
            title="Plant–environment interactions",
            details="Combine leaf, canopy and soil processes, with different time steps and shared resources.",
            link="journeys/users/maespa_synthesis.html",
        ),
    ],
)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo=Documenter.Remotes.GitHub("VirtualPlantLab", "PlantSimEngine.jl"),
    sitename="PlantSimEngine.jl",
    format=Bonito.DocumenterBonito(;
        repo="github.com/VirtualPlantLab/PlantSimEngine.jl",
        devbranch="main",
        devurl="dev",
        version=get(ENV, "GITHUB_REF_TYPE", "") == "tag" ? get(ENV, "GITHUB_REF_NAME", "dev") : "dev",
        logo="assets/logo.png",
        home,
        description="Connect process models for crop canopies, plant architectures and plant–environment interactions in Julia, with tools for AI-assisted model development.",
    ), pages=[
        "Home" => "index.md",
        "Start here" => [
            "Why PlantSimEngine?" => "introduction/why_plantsimengine.md",
            "Installation" => "prerequisites/installing_plantsimengine.md",
            "Your first simulation" => "journeys/users/one_object.md",
            "How the pieces fit" => "journeys/users/mental_model.md",
            "Help from an AI coding agent" => "agent_skill.md",
        ],
        "Couple models" => [
            "Several independent objects" => "journeys/users/several_objects.md",
            "One multiscale plant" => "journeys/users/one_plant.md",
            "Several plants" => "journeys/users/several_plants.md",
            "Connect values between objects" => "guides/multiscale/value_coupling.md",
            "Collect and plot results" => "guides/data/outputs_plotting.md",
            "Use observed values" => "guides/data/forcing_observations.md",
            "Importing an MTG" => "guides/multiscale/import_mtg.md",
            "Visualizing structure" => "guides/multiscale/visualizing_structure.md",
        ],
        "Write models" => [
            "New process or new hypothesis?" => "step_by_step/implement_a_process.md",
            "Write and test a first model" => "journeys/modelers/basic_model.md",
            "Keep scientific kernels readable" => "guides/modelers/port_existing_model.md",
            "Repository layout and test pyramid" => "guides/modelers/repository_and_tests.md",
            "Cross-object values" => "journeys/modelers/cross_object_values.md",
            "Choose a coupling mechanism" => "guides/coupling.md",
            "Model compatibility and replacement" => "step_by_step/model_switching.md",
            "Environment and cadence traits" => "journeys/modelers/environment_and_cadence.md",
            "Hard dependencies" => "journeys/modelers/hard_dependencies.md",
            "Mutable environment controllers" => "journeys/modelers/mutable_environment.md",
            "Stateful models" => "guides/modelers/stateful_models.md",
        ],
        "Environment and time" => [
            "Read an environment" => "journeys/users/environments.md",
            "Different model cadences" => "journeys/users/cadences.md",
            "Hourly, daily, and weekly" => "guides/time/hourly_daily_weekly.md",
            "Choose compatible time steps" => "guides/time/advanced_time_environment.md",
        ],
        "Growth and advanced simulations" => [
            "Modify plant structure" => "journeys/users/structure_changes.md",
            "Growth within a time step" => "tutorials/growing_plant/part1_growth.md",
            "Roots and water" => "tutorials/growing_plant/part2_roots_water.md",
            "Check a growing simulation" => "tutorials/growing_plant/part3_debugging.md",
            "Modify the environment" => "journeys/users/mutable_environments.md",
            "Control advanced execution" => "journeys/users/advanced_execution.md",
            "MAESPA-style synthesis" => "journeys/users/maespa_synthesis.md",
            "Manual calls" => "guides/multiscale/manual_calls.md",
            "Advanced coupling and hard dependencies" => "step_by_step/advanced_coupling.md",
        ],
        "Check and troubleshoot" => [
            "Common errors" => "troubleshooting/common_errors.md",
            "Inspect a simulation" => "troubleshooting/runtime_contracts.md",
            "Dependency cycles" => "troubleshooting/dependency_cycles.md",
            "Numerical reliability" => "guides/data/numerical_reliability.md",
            "Parameter fitting" => "working_with_data/fitting.md",
        ],
        "Reference and tools" => [
            "Julia language basics" => "prerequisites/julia_basics.md",
            "Why Julia?" => "introduction/why_julia.md",
            "How multiscale models execute" => "guides/multiscale/concepts.md",
            "Model execution" => "model_execution.md",
            "Model traits" => "model_traits.md",
            "Graph editor" => "guides/graph_visualizer_editor.md",
            "Environment backend extensions" => "guides/extensions/environment_backends.md",
            "Find available models" => "API/model_catalog.md",
            "Public API" => "API/API_public.md",
            "Public symbol inventory" => "API/public_symbols.md",
            "Example models" => "API/API_examples.md",
        ],
        "Contribute and migrate" => [
            "Developer guidelines" => "developers.md",
            "Internal API" => "API/API_private.md",
            "From the mapping runtime" => "migration_composite_model.md",
            "Roadmap" => "planned_features.md",
        ],
    ]
)

include(joinpath(@__DIR__, "check_static_export.jl"))
finish_static_export()

if get(ENV, "PLANTSIMENGINE_DOCS_BUILD_ONLY", "false") != "true"
    deploydocs(;
        repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
        devbranch="main",
        push_preview=true, # Visit https://VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR128 to visualize the preview of the PR #128
    )
end
