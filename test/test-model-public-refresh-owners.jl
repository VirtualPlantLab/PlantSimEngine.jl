module PublicRefreshOwnerChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI
PSE.@process "force_authority_count" verbose=false
struct Counter <: AbstractForce_Authority_CountModel end
PSE.inputs_(::Counter) = NamedTuple()
PSE.outputs_(::Counter) = (visits=0,)
PSE.run!(::Counter, status, environment, constants, context) = (status.visits += 1; nothing)

@testset "public force owns the next step without an intervening mutation" begin
    first_spec = ModelSpec(Counter(); name=:probe, on=One(id=:leaf1))
    model = CompositeModel(Object(:root; scale=:Scene),
        Object(:leaf1; scale=:Leaf, parent=:root, status=Status(visits=0)),
        Object(:leaf2; scale=:Leaf, parent=:root, status=Status(visits=0));
        applications=(first_spec,))
    simulation = run!(model; steps=1, outputs=:none)
    previous = simulation.compiled
    previous_runtime_revision = model.runtime_revision
    replacement = ModelSpec(Counter(); name=:probe, on=One(id=:leaf2))
    @test typeof(replacement) === typeof(first_spec)
    model.applications[1] = replacement
    current = Advanced.refresh_bindings!(model; force=true)
    owner_replaced = current !== previous
    @test owner_replaced
    same_compiled_schema = current isa typeof(previous)
    @test same_compiled_schema
    @test !PSE.bindings_dirty(model)
    @test only(current.applications).target_ids == [ObjectId(:leaf2)]
    @test model.runtime_revision > previous_runtime_revision
    published = model.runtime_revision
    clean = Advanced.refresh_bindings!(model)
    clean_identity_preserved = clean === current
    @test clean_identity_preserved
    @test model.runtime_revision == published
    continue!(simulation; steps=1)
    @info "force binding authority after continue" leaf1=model_status(model, :leaf1).visits leaf2=model_status(model, :leaf2).visits adopted=(simulation.compiled === current)
    @test model_status(model, :leaf1).visits == 1
    @test model_status(model, :leaf2).visits == 1
    adopted_current = simulation.compiled === current
    @test adopted_current
end

mutable struct Backend <: EA.AbstractEnvironmentBackend
    binds::Int
end
struct Handle
    generation::Int
end
EA.base_step_seconds(::Backend) = 3600.0
EA.get_nsteps(::Backend) = 4
EA.environment_variables(::Backend) = Set((:T,))
function EA.bind_environment(backend::Backend, ::Object, context, config)
    backend.binds += 1
    return Handle(backend.binds)
end
EA.sample(::Backend, handle::Handle, ::Symbol, time) = Float64(handle.generation)

PSE.@process "force_authority_environment" verbose=false
struct EnvironmentProbe <: AbstractForce_Authority_EnvironmentModel end
PSE.inputs_(::EnvironmentProbe) = NamedTuple()
PSE.outputs_(::EnvironmentProbe) = (seen=0.0, visits=0)
PSE.environment_inputs_(::EnvironmentProbe) = (T=0.0,)
function PSE.run!(::EnvironmentProbe, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    return nothing
end

@testset "public environment force installs its newly compiled handle" begin
    backend = Backend(0)
    model = CompositeModel(Object(:leaf; scale=:Leaf,
        status=Status(seen=0.0, visits=0)); applications=(
            ModelSpec(EnvironmentProbe(); name=:probe, on=One(id=:leaf),
                environment=Environment(provider=:force_probe)),), environment=backend)
    simulation = run!(model; steps=1, outputs=:none)
    previous = simulation.environment_bindings
    previous_runtime_revision = model.runtime_revision
    current = Advanced.refresh_environment_bindings!(model, simulation.compiled; force=true)
    key = (:probe, ObjectId(:leaf))
    expected_generation = current.by_target[key].handle.generation
    owner_replaced = current !== previous
    @test owner_replaced
    @test expected_generation > previous.by_target[key].handle.generation
    @test !PSE.environment_bindings_dirty(model)
    @test model.runtime_revision > previous_runtime_revision
    published = model.runtime_revision
    clean = Advanced.refresh_environment_bindings!(model, simulation.compiled)
    clean_identity_preserved = clean === current
    @test clean_identity_preserved
    @test model.runtime_revision == published
    continue!(simulation; steps=1)
    adopted = simulation.environment_bindings === current
    @info "force environment authority after continue" seen=model_status(model, :leaf).seen expected_generation adopted
    @test adopted
    @test model_status(model, :leaf).seen == Float64(expected_generation)
    @test model_status(model, :leaf).visits == 2
end

PSE.@process "force_authority_controller" verbose=false
struct Controller <: AbstractForce_Authority_ControllerModel end
PSE.inputs_(::Controller) = NamedTuple()
PSE.outputs_(::Controller) = (visits=0,)
function PSE.run!(::Controller, status, environment, constants, context)
    status.visits += 1
    if status.visits == 2
        model = runtime_model(context)
        model.applications[2] = ModelSpec(Counter(); name=:probe, on=One(id=:leaf2))
        Advanced.refresh_bindings!(model; force=true)
    end
    return nothing
end

@testset "public force inside a kernel wakes the shared lifecycle barrier" begin
    model = CompositeModel(Object(:root; scale=:Scene, status=Status(visits=0)),
        Object(:leaf1; scale=:Leaf, parent=:root, status=Status(visits=0)),
        Object(:leaf2; scale=:Leaf, parent=:root, status=Status(visits=0));
        applications=(ModelSpec(Controller(); name=:controller, on=One(id=:root)),
            ModelSpec(Counter(); name=:probe, on=One(id=:leaf1))))
    simulation = run!(model; steps=2, outputs=:none)
    @info "in-kernel force binding authority" leaf1=model_status(model, :leaf1).visits leaf2=model_status(model, :leaf2).visits adopted=(simulation.compiled === model.binding_cache)
    @test model_status(model, :root).visits == 2
    @test model_status(model, :leaf1).visits == 1
    @test model_status(model, :leaf2).visits == 1
    adopted_current = simulation.compiled === model.binding_cache
    @test adopted_current
    @test simulation.runtime_revision == model.runtime_revision
end

PSE.@process "force_authority_capture" verbose=false
struct Capture{C} <: AbstractForce_Authority_CaptureModel
    context::C
end
PSE.inputs_(::Capture) = NamedTuple()
PSE.outputs_(::Capture) = (visits=0,)
function PSE.run!(model::Capture, status, environment, constants, context)
    status.visits += 1
    model.context[] = context
    return nothing
end

@testset "forced owner replacement invalidates a pending call evaluation" begin
    for force_environment in (false, true)
        capture = Ref{Any}()
        model = CompositeModel(Object(:root; scale=:Scene, status=Status(visits=0)),
            Object(:leaf; scale=:Leaf, parent=:root, status=Status(visits=0));
            applications=(ModelSpec(Capture(capture); name=:capture, on=One(id=:root),
                    calls=(child=One(id=:leaf, application=:probe),)),
                ModelSpec(Counter(); name=:probe, on=One(id=:leaf))),
            environment=Backend(0))
        simulation = run!(model; steps=1, outputs=:all)
        evaluation = evaluate_call!(capture[], :child)
        @test model_status(model, :leaf).visits == 1
        previous = model.runtime_revision
        if force_environment
            Advanced.refresh_environment_bindings!(model, simulation.compiled; force=true)
        else
            Advanced.refresh_bindings!(model; force=true)
        end
        @test model.runtime_revision > previous
        @test_throws ArgumentError accept_call!(evaluation)
        @test model_status(model, :leaf).visits == 1
        @test isempty(get(outputs(simulation), (:probe, ObjectId(:leaf), :visits), []))
    end
end


@testset "force rebinds status permissions before staging a new selector's defaults" begin
    first_spec = ModelSpec(Counter(); name=:probe, on=Many(kind=:a))
    model = CompositeModel(Object(:a; kind=:a), Object(:b; kind=:b);
        applications=(first_spec,))
    previous = model.scenario_plan_cache
    catalog = model.registry.objects.catalog
    families = catalog.families
    @test isempty(previous.status_manifest.raw_families)
    replacement = ModelSpec(Counter(); name=:probe, on=Many(kind=:b))
    @test typeof(replacement) === typeof(first_spec)
    model.applications[1] = replacement
    current = Advanced.refresh_bindings!(model; force=true)
    preparation = model.scenario_plan_cache
    @test preparation !== previous
    @test preparation.status_manifest !== catalog.status_manifest
    @test model.registry.objects.catalog.status_manifest === preparation.status_manifest
    @test model.registry.objects.catalog.families === families
    @test preparation.status_manifest.raw_families === previous.status_manifest.raw_families
    @test isnothing(model_status(model, :a))
    @test model_status(model, :b).visits == 0

    b = Object(:born_b; kind=:b)
    register_object!(model, b)
    wrong = Object(:wrong_a; kind=:a, status=Status(visits=2))
    source = wrong.status
    @test_throws ArgumentError register_object!(model, wrong)
    @test wrong.status === source
    @test !haskey(model.registry.objects, wrong.id)
    inactive = Object(:inactive_a; kind=:a)
    register_object!(model, inactive)
    run!(model; steps=1, outputs=:none)
    @test model_status(model, :b).visits == 1
    @test model_status(model, b.id).visits == 1
    @test isnothing(model_status(model, inactive.id))
    @test current.scenario_plan.authoring.preparation === preparation
end

@testset "force does not turn materialized defaults into RAW evidence" begin
    model = CompositeModel(Object(:leaf; kind=:a);
        applications=(ModelSpec(Counter(); name=:probe, on=Many(kind=:a)),))
    raw = model.scenario_plan_cache.status_manifest.raw_families
    @test isempty(raw)
    run!(model; steps=0, outputs=:none)
    status = model_status(model, :leaf)
    reference = PSE.refvalue(status, :visits)
    Advanced.refresh_bindings!(model; force=true)
    @test model.scenario_plan_cache.status_manifest.raw_families === raw
    @test model.registry.objects.catalog.status_manifest === model.scenario_plan_cache.status_manifest
    @test model_status(model, :leaf) === status
    @test PSE.refvalue(status, :visits) === reference
    @test object_id(model, status) === ObjectId(:leaf)
end

PSE.@process "force_authority_new_status_field" verbose=false
struct ChangingFields{M,D,K} <: AbstractForce_Authority_New_Status_FieldModel
    extra::M
    declarations::D
    kernels::K
end
PSE.inputs_(::ChangingFields) = (;)
function PSE.outputs_(model::ChangingFields)
    model.declarations[] += 1
    return model.extra[] ? (visits=0, extra=0) : (visits=0,)
end
function PSE.run!(model::ChangingFields, status, environment, constants, context)
    model.kernels[] += 1
    status.visits += 1
    return nothing
end

@testset "an incompatible mutable declaration records an authoritative error without publishing state" begin
    extra, declarations, kernels = Ref(false), Ref(0), Ref(0)
    original = ModelSpec(ChangingFields(extra, declarations, kernels); name=:probe, on=One(id=:leaf))
    supplied = Status(visits=5)
    model = CompositeModel(Object(:leaf; status=supplied); applications=(original,))
    run!(model; steps=0, outputs=:none)
    registry, preparation, compiled = model.registry, model.scenario_plan_cache, model.binding_cache
    environment = model.environment_binding_cache
    status = model_status(model, :leaf)
    reference = PSE.refvalue(status, :visits)
    source_owners = copy(model.status_source_owners)
    source_ids = copy(model.status_source_identities)
    extra[] = true # SAME immutable ModelSpec and SAME mutable model instance
    @test only(model.applications) === original
    failure = try
        Advanced.refresh_bindings!(model; force=true)
        nothing
    catch exception
        exception
    end
    @test failure isa ArgumentError
    @test occursin("Construct a new CompositeModel", sprint(showerror, failure))
    rejected = model.scenario_plan_cache
    @test rejected !== preparation
    @test rejected.status_manifest isa PSE.ScenarioPreparationFailure
    @test rejected.status_manifest.phase === :status_manifest
    @test rejected.status_manifest.error === failure
    @test model.registry === registry
    @test model.binding_cache === compiled
    @test model.environment_binding_cache === environment
    @test model_status(model, :leaf) === status
    @test PSE.refvalue(status, :visits) === reference
    @test status.visits == 5
    @test model.status_source_owners == source_owners
    @test model.status_source_identities == source_ids
    @test object_id(model, status) === ObjectId(:leaf)
    after_failure = declarations[]
    @test_throws ArgumentError run!(model; steps=1, outputs=:none)
    @test_throws ArgumentError Advanced.refresh_bindings!(model)
    @test declarations[] == after_failure
    @test kernels[] == 0
    @test status.visits == 5

    extra[] = false
    @test_throws ArgumentError run!(model; steps=0, outputs=:none)
    @test declarations[] == after_failure
    Advanced.refresh_bindings!(model; force=true) # explicit recovery within old S
    @test model.registry.objects.catalog.status_manifest === model.scenario_plan_cache.status_manifest
    run!(model; steps=1, outputs=:none)
    @test model_status(model, :leaf) === status
    @test PSE.refvalue(status, :visits) === reference
    @test status.visits == 6
    @test kernels[] == 1
end

end

module SelectiveRefreshOwnerChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "selective_force_authority_probe" verbose=false
PSE.@process "selective_force_authority_controller" verbose=false
struct Counter <: AbstractSelective_Force_Authority_ProbeModel end
PSE.inputs_(::Counter) = NamedTuple()
PSE.outputs_(::Counter) = (visits=0,)
PSE.run!(::Counter, status, environment, constants, context) = (status.visits += 1; nothing)

function check_memberships(simulation)
    rows = collect_outputs(simulation, :chosen; sink=nothing)
    scientific_rows = [(row.object_id, row.timestep, row.value) for row in rows]
    @info "selective force authority" scientific_rows
    @test scientific_rows == [(:leaf1, 1, 1), (:leaf2, 2, 1)]
    targets = simulation.output_requests[:chosen].targets
    @test [(membership.start_time, membership.end_time)
        for membership in targets[ObjectId(:leaf1)].memberships] == [(0.0, 1.0)]
    @test haskey(targets, ObjectId(:leaf2))
    if haskey(targets, ObjectId(:leaf2))
        @test [(membership.start_time, membership.end_time)
            for membership in targets[ObjectId(:leaf2)].memberships] == [(2.0, nothing)]
    end
    model = runtime_model(simulation)
    @test model_status(model, :leaf1).visits == 1
    @test model_status(model, :leaf2).visits == 1
    @test outputs(simulation)[(:probe, ObjectId(:leaf1), :visits)] == [(1.0, 1)]
    @test outputs(simulation)[(:probe, ObjectId(:leaf2), :visits)] == [(2.0, 1)]
end

@testset "public force refreshes selective membership, including a later pending addition" begin
    for pending_addition in (false, true)
        model = CompositeModel(Object(:root; scale=:Scene),
            Object(:leaf1; scale=:Leaf, parent=:root, status=Status(visits=0)),
            Object(:leaf2; scale=:Leaf, parent=:root, status=Status(visits=0));
            applications=(ModelSpec(Counter(); name=:probe, on=One(id=:leaf1)),))
        request = OutputRequest(Many(scale=:Leaf), :visits;
            name=:chosen, application=:probe)
        simulation = run!(model; steps=1, outputs=request)
        previous_revision = PSE.model_revision(model)
        model.applications[1] = ModelSpec(Counter(); name=:probe, on=One(id=:leaf2))
        current = Advanced.refresh_bindings!(model; force=true)
        @test PSE.model_revision(model) == previous_revision
        pending_addition && register_object!(model, Object(:unrelated; scale=:Axis, parent=:root))
        continue!(simulation; steps=1)
        adopted = simulation.compiled === model.binding_cache
        @test adopted
        if !pending_addition
            adopted_forced_owner = simulation.compiled === current
            @test adopted_forced_owner
        end
        @info "selective force followed by pending addition" pending_addition adopted
        check_memberships(simulation)
    end
end

struct Controller <: AbstractSelective_Force_Authority_ControllerModel
    birth::Bool
end
PSE.inputs_(::Controller) = NamedTuple()
PSE.outputs_(::Controller) = (visits=0,)
function PSE.run!(controller::Controller, status, environment, constants, context)
    status.visits += 1
    if status.visits == 2
        model = runtime_model(context)
        model.applications[2] = ModelSpec(Counter(); name=:probe, on=One(id=:leaf2))
        Advanced.refresh_bindings!(model; force=true)
        controller.birth && register_object!(model, Object(:unrelated; scale=:Axis, parent=:root))
    end
    return nothing
end

@testset "in-kernel force reconciles selective membership before the remaining application" begin
    for birth in (false, true)
        model = CompositeModel(Object(:root; scale=:Scene, status=Status(visits=0)),
            Object(:leaf1; scale=:Leaf, parent=:root, status=Status(visits=0)),
            Object(:leaf2; scale=:Leaf, parent=:root, status=Status(visits=0));
            applications=(ModelSpec(Controller(birth); name=:controller, on=One(id=:root)),
                ModelSpec(Counter(); name=:probe, on=One(id=:leaf1))))
        request = OutputRequest(Many(scale=:Leaf), :visits; name=:chosen, application=:probe)
        simulation = run!(model; steps=2, outputs=request)
        @test model_status(model, :root).visits == 2
        adopted = simulation.compiled === model.binding_cache
        @test adopted
        check_memberships(simulation)
    end
end

end
