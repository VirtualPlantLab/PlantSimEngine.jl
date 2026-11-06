module ScenarioAuthoringChecks

using Dates, PlantSimEngine, Random, Test
using PlantSimEngine.GraphEditor
const PSE = PlantSimEngine

PSE.@process "scenario_authoring_probe" verbose=false
PSE.@process "scenario_authoring_constant" verbose=false

struct Probe{R,C,H} <: AbstractScenario_Authoring_ProbeModel
    rng::R
    declarations::C
    hints::H
end
function PSE.outputs_(model::Probe)
    model.declarations[] += 1
    return (value=0.0, scratch=zeros(2), visits=0)
end
function PSE.environment_hint(model::Probe)
    model.hints[] += 1
    return NamedTuple()
end
function PSE.run!(model::Probe, status, environment, constants, context)
    status.value += rand(model.rng)
    status.scratch[1] += 1
    status.visits += 1
    return nothing
end

struct ConstantProbe <: AbstractScenario_Authoring_ConstantModel
    value::Float64
end
PSE.outputs_(::ConstantProbe) = (value=0.0, visits=0)
function PSE.run!(model::ConstantProbe, status, environment, constants, context)
    status.value = model.value
    status.visits += 1
    return nothing
end

@testset "constructor prepares typed authoring metadata without materializing state" begin
    declarations, hints = Ref(0), Ref(0)
    rng = Xoshiro(71)
    expected_rng = copy(rng)
    conversions = Symbol[]
    transform(variable, value) = (push!(conversions, variable); value)
    model = CompositeModel(Object(1; scale=:Leaf, status=Status(seed=1.0));
        applications=(ModelSpec(Probe(rng, declarations, hints);
            name=:probe, on=Many(scale=:Leaf)),), status_transform=transform)
    preparation = model.scenario_plan_cache
    @test preparation isa PSE.ScenarioPreparation
    @test isnothing(preparation.failure)
    @test isnothing(preparation.resolved)
    @test preparation.authored isa Tuple
    recipe = only(preparation.authored)
    @test recipe isa PSE.AuthoredApplicationRecipe
    @test recipe.output_names == (:value, :scratch, :visits)
    @test recipe.canonical_output_names == recipe.output_names
    @test recipe.spec === only(model.applications)
    @test declarations[] == hints[] == 1
    @test conversions == [:seed]
    @test NamedTuple(model_status(model, 1)) == (seed=1.0,)
    @test isnothing(PSE.Advanced.compiled_bindings(model))
    @test rand(copy(rng)) == rand(copy(expected_rng))

    # Resolve the existing recipe against real membership and time without
    # invoking its moved port/hint declarations a second time.
    resolved = PSE._compile_model_applications(model, Tuple(model.applications), PSE._model_timeline(model))
    @test only(resolved).target_ids == [ObjectId(1)]
    @test declarations[] == hints[] == 1
    @test conversions == [:seed]
    @test model.scenario_plan_cache === preparation

    simulation = run!(model; outputs=:all)
    first_draw = rand(expected_rng)
    @test model_status(model, 1).value == first_draw
    @test model_status(model, 1).visits == 1
    @test hints[] == 1
    original_scratch = model_status(model, 1).scratch
    converted_before_birth = length(conversions)
    declaration_count = declarations[]
    register_object!(model, Object(0; scale=:Leaf, status=Status(seed=2.0)))
    @test model.scenario_plan_cache === preparation
    @test preparation.authored === (recipe,)
    @test conversions[(converted_before_birth + 1):end] == [:seed]
    @test declarations[] == declaration_count
    @test hints[] == 1
    step!(simulation)
    newborn_draw, older_draw = rand(expected_rng), rand(expected_rng)
    @test model_status(model, 0).value == newborn_draw
    @test model_status(model, 1).value == first_draw + older_draw
    @test model_status(model, 0).visits == 1
    @test model_status(model, 1).visits == 2
    @test model_status(model, 0).scratch !== original_scratch
    @test model_status(model, 0).scratch == [1.0, 0.0]
    @test original_scratch == [2.0, 0.0]

    # Configuration reconstruction retains identical authored specs and only
    # refreshes runtime resolution, never preparing an intermediate model.
    old_declarations = declarations[]
    edited = apply_model_graph_edit(model,
        SetCompositeModelEnvironment((duration=Hour(1),)))
    edited_probe = PSE.model_(only(edited.applications))
    @test edited_probe.declarations[] == old_declarations
    @test edited_probe.hints[] == hints[]
    @test declarations[] == old_declarations
    @test hints[] == 1
    @test edited.scenario_plan_cache.owner === edited
    @test isnothing(edited.scenario_plan_cache.failure)
end

@testset "structural reconstruction shares recipes but owns its target snapshot" begin
    declarations, hints = Ref(0), Ref(0)
    spec = ModelSpec(Probe(Xoshiro(17), declarations, hints);
        name=:probe, on=Many(scale=:Leaf))
    first_model = CompositeModel(Object(1; scale=:Leaf); applications=(spec,))
    first_snapshot = PSE._prepare_scenario_plan(first_model)
    first_owner = first_model.scenario_plan_cache
    next_model = CompositeModel(Object(2; scale=:Leaf); applications=(spec,))
    # Internal closed-registry reconstruction passes through this field. Its
    # reusable immutable metadata must not share the mutable resolved slot.
    next_model.scenario_plan_cache = first_owner
    before = declarations[]
    next_owner = PSE._scenario_preparation(next_model)
    @test next_owner !== first_owner
    @test next_owner.owner === next_model
    @test next_owner.authored === first_owner.authored
    @test isnothing(next_owner.resolved)
    @test declarations[] == before
    register_object!(next_model, Object(3; scale=:Leaf))
    next_snapshot = PSE._prepare_scenario_plan(next_model)
    @test only(next_snapshot.target_ids) == [ObjectId(2), ObjectId(3)]
    @test first_owner.resolved === first_snapshot
    @test only(first_snapshot.target_ids) == [ObjectId(1)]
end

@testset "future scopes, targets and overrides resolve only against the first run" begin
    models = PSE.ObjectModelOverrides(ConstantProbe(1.0),
        Dict(ObjectId(:future_leaf) => ConstantProbe(7.0)))
    model = CompositeModel(Object(:root; scale=:Plant); applications=(
        ModelSpec(models; name=:probe,
            on=One(scale=:Leaf, within=Scope(ObjectId(:future_root))), every=Hour(2)),),
        environment=(duration=Hour(1),))
    preparation = model.scenario_plan_cache
    @test isnothing(preparation.failure)
    @test only(preparation.authored).target_matcher.scope isa Scope
    report = PSE.compile_model_report(model)
    @test !isempty(report.diagnostics)
    @test isnothing(report.compiled)
    @test model.scenario_plan_cache === preparation
    @test isnothing(preparation.resolved)
    @test_throws Exception run!(model; steps=0)
    @test isnothing(preparation.failure) # cardinality is not a frozen authoring error

    register_object!(model, Object(:future_leaf; scale=:Leaf, parent=:root))
    register_object!(model, Object(:future_root; scale=:Plant, parent=:root))
    reparent_object!(model, :future_leaf, :future_root)
    model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(model)
    simulation = run!(model; steps=3, outputs=:all)
    @test model.scenario_plan_cache === preparation
    @test only(simulation.compiled.applications).target_ids == [ObjectId(:future_leaf)]
    @test only(simulation.compiled.applications).clock.dt == 1.0
    @test model_status(model, :future_leaf).value == 7.0
    @test model_status(model, :future_leaf).visits == 3
end

@testset "cadence rebuilding after registration preserves authored metadata" begin
    declarations, hints = Ref(0), Ref(0)
    model = CompositeModel(Object(1; scale=:Leaf); applications=(
        ModelSpec(Probe(Xoshiro(59), declarations, hints); name=:probe,
            on=Many(scale=:Leaf), every=Hour(2)),),
        environment=(duration=Hour(1),))
    preparation = model.scenario_plan_cache
    authored = preparation.authored
    first = run!(model; steps=0, outputs=:all)
    @test first.compiled.scenario_plan.timeline.base_step_seconds == 3600.0
    @test only(first.compiled.applications).clock.dt == 2.0
    register_object!(model, Object(2; scale=:Leaf))
    @test model.scenario_plan_cache === preparation
    @test isnothing(preparation.resolved)
    model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(model)

    # Pure application resolution reuses both moved declaration hooks. Real
    # status/default and contract preparation may still read outputs_ later.
    declaration_count, hint_count = declarations[], hints[]
    applications = PSE._compile_model_applications(model, Tuple(model.applications),
        PSE._model_timeline(model))
    @test only(applications).target_ids == [ObjectId(1), ObjectId(2)]
    @test only(applications).clock.dt == 1.0
    @test declarations[] == declaration_count
    @test hints[] == hint_count

    # Automatic cadence forcing must commit its newly resolved plan even with
    # a pending addition, while retaining the constructor's authoring owner.
    restarted = run!(model; steps=3, outputs=:all)
    @test model.scenario_plan_cache === preparation
    @test preparation.authored === authored
    @test hints[] == hint_count
    @test preparation.resolved.plan === restarted.compiled.scenario_plan
    @test restarted.compiled.scenario_plan.timeline.base_step_seconds == 7200.0
    @test only(restarted.compiled.applications).clock.dt == 1.0
    @test first.compiled.scenario_plan.timeline.base_step_seconds == 3600.0
    @test current_step(first) == 0
    @test current_step(restarted) == 3
    @test model_status(model, 1).visits == model_status(model, 2).visits == 3
    @test model_status(model, 1).scratch !== model_status(model, 2).scratch

    # The private snapshot force has the same resolution-only semantics.
    previous_snapshot = preparation.resolved
    forced_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test forced_snapshot !== previous_snapshot
    @test preparation.resolved === forced_snapshot
    @test model.scenario_plan_cache === preparation
    @test preparation.authored === authored
    @test hints[] == hint_count

    # An explicit public compiler force still refreshes authored declarations.
    PSE.Advanced.refresh_bindings!(model; force=true)
    @test model.scenario_plan_cache !== preparation
    @test hints[] == hint_count + 1
end

@testset "authoring errors stay structured, inspectable and repairable" begin
    invalid = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(ConstantProbe(1.0); name=:missing),))
    preparation = invalid.scenario_plan_cache
    @test preparation.failure isa PSE.ScenarioPreparationFailure
    @test preparation.failure.phase == :application_selector
    @test preparation.failure.application_id == :missing
    @test preparation.failure.error isa ErrorException
    @test_throws ErrorException run!(invalid; steps=0)
    report = PSE.compile_model_report(invalid)
    @test !isempty(report.diagnostics)
    @test any(row -> occursin("selector", row.message), report.diagnostics)
    @test isnothing(PSE.Advanced.compiled_bindings(invalid))

    repaired = apply_model_graph_edit(invalid, UpdateModelApplication(
        GlobalApplicationRef(:missing), ConstantProbe(2.0), :missing,
        One(id=:root), nothing,
    ))
    simulation = run!(repaired)
    @test final_state(simulation).value == 2.0
    @test isnothing(repaired.scenario_plan_cache.failure)
    @test invalid.scenario_plan_cache === preparation
    @test preparation.failure.application_id == :missing
end

struct BrokenDeclarations <: AbstractScenario_Authoring_ConstantModel
    fail::Base.RefValue{Bool}
    calls::Base.RefValue{Int}
end
function PSE.outputs_(model::BrokenDeclarations)
    model.calls[] += 1
    model.fail[] && throw(ArgumentError("intentional authored declaration failure"))
    return (value=0.0, visits=0)
end
PSE.run!(::BrokenDeclarations, status, environment, constants, context) = (status.visits += 1; nothing)

@testset "a captured declaration error is propagated without re-evaluation" begin
    fail, calls = Ref(true), Ref(0)
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(BrokenDeclarations(fail, calls); name=:broken, on=One(id=:root)),),
        environment=(duration=Hour(1),))
    failure = model.scenario_plan_cache.failure
    @test failure.phase == :output_ports
    @test failure.application_id == :broken
    @test failure.error isa ArgumentError
    @test calls[] == 1
    @test_throws ArgumentError run!(model; steps=0)
    @test calls[] == 1
    report = PSE.compile_model_report(model)
    @test any(row -> occursin("intentional authored declaration failure", row.message), report.diagnostics)
    @test calls[] == 1 # diagnostic recovery works on its owned structural copy
    fail[] = false
    PSE.Advanced.refresh_bindings!(model; force=true)
    @test isnothing(model.scenario_plan_cache.failure)
    @test final_state(run!(model)).visits == 1
    # A failed force refresh must not let an older compiled cache hide the
    # newly recorded declaration error on a later normal run/snapshot query.
    fail[] = true
    @test_throws ArgumentError PSE.Advanced.refresh_bindings!(model; force=true)
    failed_count = calls[]
    @test_throws ArgumentError run!(model; steps=0)
    @test_throws ArgumentError PSE._prepare_scenario_plan(model)
    @test calls[] == failed_count

    # Automatic cadence rebuilding is an ordinary run, not permission to
    # reevaluate a declaration already captured by a failed force refresh.
    model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(model)
    @test_throws ArgumentError run!(model; steps=0)
    @test calls[] == failed_count
end

struct ModuleDeclarationError <: Exception
    owner::Module
end
Base.showerror(io::IO, ::ModuleDeclarationError) = print(io, "invalid module declaration")

struct ModuleDeclaration <: AbstractScenario_Authoring_ConstantModel end
PSE.outputs_(::ModuleDeclaration) = throw(ModuleDeclarationError(@__MODULE__))

@testset "diagnostic copies retain opaque exceptions without copying modules" begin
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(ModuleDeclaration(); name=:module_error, on=One(id=:root)),))
    failure = model.scenario_plan_cache.failure
    @test failure.error isa ModuleDeclarationError
    @test failure.error.owner === @__MODULE__
    owned = deepcopy(model)
    @test owned.scenario_plan_cache.owner === owned
    @test owned.scenario_plan_cache.failure.error === failure.error
    @test owned.scenario_plan_cache.failure.backtrace !== failure.backtrace
    @test owned.scenario_plan_cache.failure.backtrace == failure.backtrace
    @test_throws ModuleDeclarationError run!(owned; steps=0)
    report = PSE.compile_model_report(model)
    @test any(row -> occursin("invalid module declaration", row.message), report.diagnostics)
    @test model.scenario_plan_cache.failure === failure
    @test isnothing(PSE.Advanced.compiled_bindings(model))
end

end # module ScenarioAuthoringChecks
