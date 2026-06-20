#using Pkg
#Pkg.develop("PlantSimEngine")
using PlantSimEngine
using PlantMeteo
using DataFrames, CSV
using Documenter
using CairoMakie
using PlantSimEngine.Examples

function build_scene_graph_example()
    output_dir = joinpath(@__DIR__, "src", "assets")
    mkpath(output_dir)
    scene = Scene(
        Object(:plant; name=:plant, scale=:Plant, kind=:plant, status=Status(TT=12.0));
        applications=(
            ModelSpec(ToyDegreeDaysCumulModel(); name=:degree_days) |>
                AppliesTo(One(name=:plant)),
            ModelSpec(ToyLAIModel(); name=:lai) |>
                AppliesTo(One(name=:plant)),
            ModelSpec(Beer(0.6); name=:light_interception) |>
                AppliesTo(One(name=:plant)),
        ),
    )
    write_scene_graph_view(
        joinpath(output_dir, "scene_graph_example.html"),
        scene,
    )
end

build_scene_graph_example()

DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames, CSV, CairoMakie); recursive=true)

makedocs(;
    modules=[PlantSimEngine],
    authors="Rémi Vezy <VEZY@users.noreply.github.com> and contributors",
    repo=Documenter.Remotes.GitHub("VirtualPlantLab", "PlantSimEngine.jl"),
    sitename="PlantSimEngine.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://VirtualPlantLab.github.io/PlantSimEngine.jl",
        edit_link="main",
        assets=String[],
        size_threshold=700000
    ), pages=[
        "Home" => "index.md",
        "Introduction" => [
            "Why PlantSimEngine ?" => "./introduction/why_plantsimengine.md",
            "Why Julia ?" => "./introduction/why_julia.md",
        ],
        "Prerequisites" => [
            "Installing and running PlantSimEngine" => "./prerequisites/installing_plantsimengine.md",
            "Key Concepts" => "./prerequisites/key_concepts.md",
            "Julia language basics" => "./prerequisites/julia_basics.md",
        ],
        "Getting Started" => [
            "Quickstart" => "./scene_object/quickstart.md",
            "Detailed first simulation" => "./step_by_step/detailed_first_example.md",
            "Port an existing model" => "./guides/modelers/port_existing_model.md",
            "Migrating from mappings" => "migration_scene_object.md",
        ],
        "Building Scenarios" => [
            "Coupling models" => "./guides/coupling.md",
            "Visualize and edit a Scene" => "./guides/graph_visualizer_editor.md",
            "Model Switching" => "./step_by_step/model_switching.md",
            "Implementing a process" => "./step_by_step/implement_a_process.md",
            "Implementing a model" => "./step_by_step/implement_a_model.md",
            "Advanced coupling and hard dependencies" => "./step_by_step/advanced_coupling.md",
            "Implementing a model : additional notes" => "./step_by_step/implement_a_model_additional.md",
        ],
        "Multiscale Scenes" => [
            "How scenes execute" => "./guides/multiscale/concepts.md",
            "From one object" => "./guides/multiscale/from_one_object.md",
            "Value coupling" => "./guides/multiscale/value_coupling.md",
            "Importing an MTG" => "./guides/multiscale/import_mtg.md",
            "Manual calls" => "./guides/multiscale/manual_calls.md",
            "Visualizing structure" => "./guides/multiscale/visualizing_structure.md",
        ],
        "Growing Plant Tutorial" => [
            "Part 1: growth" => "./tutorials/growing_plant/part1_growth.md",
            "Part 2: roots and water" => "./tutorials/growing_plant/part2_roots_water.md",
            "Part 3: debugging" => "./tutorials/growing_plant/part3_debugging.md",
        ],
        "Time And Environment" => [
            "Understanding cadence" => "./guides/time/multirate_concepts.md",
            "Hourly, daily, and weekly" => "./guides/time/hourly_daily_weekly.md",
            "Advanced configuration" => "./guides/time/advanced_time_environment.md",
        ],
        "Data And Analysis" => [
            "Environment inputs" => "./guides/data/environment_inputs.md",
            "Collecting and plotting outputs" => "./guides/data/outputs_plotting.md",
            "Forcing observations" => "./guides/data/forcing_observations.md",
            "Numerical reliability" => "./guides/data/numerical_reliability.md",
            "Parameter fitting" => "./working_with_data/fitting.md",
        ],
        "Troubleshooting" => [
            "Common errors" => "./troubleshooting/common_errors.md",
            "Runtime contracts" => "./troubleshooting/runtime_contracts.md",
            "Dependency cycles" => "./troubleshooting/dependency_cycles.md",
            "State and repeated updates" => "./guides/modelers/stateful_models.md",
            "Downstream testing" => "./troubleshooting_and_testing/downstream_tests.md",
        ],
        "Model execution" => "model_execution.md",
        "Model traits" => "model_traits.md",
        "AI agent skill" => "agent_skill.md",
        "API" => [
            "Public API" => "./API/API_public.md",
            "Public symbol inventory" => "./API/public_symbols.md",
            "Example models" => "./API/API_examples.md",
            "Internal API" => "./API/API_private.md",],
        "Development designs" => [
            "Public API refinement decisions" => "./dev/public_api_refinement_decisions.md",
            "Public API refinement completion audit" => "./dev/public_api_refinement_completion_audit.md",
            "Unified scene/object design" => "./dev/unified_scene_object_design.md",
            "Unified scene/object implementation plan" => "./dev/unified_scene_object_implementation_plan.md",
            "Unified scene/object completion audit" => "./dev/unified_scene_object_completion_audit.md",
            "MAESPA-style scene example handoff" => "./dev/maespa_scene_handoff.md",
            "Code cleanup audit" => "./dev/code_cleanup_audit.md",
            "Release notes handoff" => "./dev/release_notes_handoff.md",
        ],
        "Developer guidelines" => "developers.md",
        "Roadmap" => "planned_features.md",
    ]
)

if get(ENV, "PLANTSIMENGINE_DOCS_BUILD_ONLY", "false") != "true"
    deploydocs(;
        repo="github.com/VirtualPlantLab/PlantSimEngine.jl.git",
        devbranch="main",
        push_preview=true, # Visit https://VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR128 to visualize the preview of the PR #128
    )
end
