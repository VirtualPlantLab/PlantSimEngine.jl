module PreparedAuthoringOwnerChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "prepared_authoring_owner_probe" verbose=false

struct Probe{H,M} <: AbstractPrepared_Authoring_Owner_ProbeModel
    hint_calls::H
    empty_hint::M
end
PSE.inputs_(::Probe) = NamedTuple()
PSE.outputs_(::Probe) = (visits=0,)
function PSE.environment_hint(model::Probe)
    model.hint_calls[] += 1
    return model.empty_hint[] ? NamedTuple() : nothing
end
PSE.run!(::Probe, status, environment, constants, context) = (status.visits += 1; nothing)

function fixture(; selector=Many(scale=:Leaf))
    hint_calls, empty_hint = Ref(0), Ref(false)
    model = CompositeModel(Object(:root; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:root);
        applications=(ModelSpec(Probe(hint_calls, empty_hint); name=:probe, on=selector),))
    return (; model, hint_calls, empty_hint)
end

@testset "canonical lifecycle consumes the genuine prepared declaration owner" begin
    data = fixture()
    simulation = run!(data.model; steps=1, outputs=:all)
    plan = simulation.compiled.scenario_plan
    preparation = data.model.scenario_plan_cache
    @test plan.authoring.preparation === preparation
    @test preparation.owner === data.model
    @test preparation.source_specs === Tuple(data.model.applications)
    @test data.hint_calls[] == 1
    original_ref = PSE.refvalue(model_status(data.model, :leaf), :visits)

    register_object!(data.model, Object(:born; scale=:Leaf, parent=:root))
    step!(simulation)
    @test simulation.compiled.scenario_plan === plan
    @test simulation.compiled.scenario_plan.authoring.preparation === preparation
    @test data.model.scenario_plan_cache === preparation
    @test data.hint_calls[] == 1
    @test model_status(data.model, :leaf).visits == 2
    @test model_status(data.model, :born).visits == 1
    @test PSE.refvalue(model_status(data.model, :leaf), :visits) === original_ref

    reparent_object!(data.model, :born, :leaf)
    step!(simulation)
    remove_object!(data.model, :born)
    step!(simulation)
    @test data.hint_calls[] == 1
    @test simulation.compiled.scenario_plan === plan
    @test model_status(data.model, :leaf).visits == 4
    @test collect(outputs(simulation)[(:probe, ObjectId(:born), :visits)]) == [(2.0, 1), (3.0, 2)]
end

@testset "public force installs the current owner even when hint result types change" begin
    data = fixture()
    simulation = run!(data.model; steps=1, outputs=:all)
    old_compiled = simulation.compiled
    old_preparation = data.model.scenario_plan_cache
    # These two valid hints normalize identically, but their authored A types
    # differ. The runtime owner stores the preparation, not a copied A tuple.
    data.empty_hint[] = true
    current = Advanced.refresh_bindings!(data.model; force=true)
    new_preparation = data.model.scenario_plan_cache
    @test new_preparation !== old_preparation
    @test typeof(new_preparation) !== typeof(old_preparation)
    @test current !== old_compiled
    @test current isa typeof(old_compiled)
    @test current.scenario_plan.authoring.preparation === new_preparation
    @test data.hint_calls[] == 2
    @test !PSE.bindings_dirty(data.model)
    @test current.revision == old_compiled.revision

    # No intervening birth/revision is needed to make public force authoritative.
    step!(simulation)
    @test simulation.compiled === current
    @test simulation.compiled.scenario_plan.authoring.preparation === new_preparation
    @test data.hint_calls[] == 2
    @test model_status(data.model, :leaf).visits == 2
    register_object!(data.model, Object(:born; scale=:Leaf, parent=:root))
    step!(simulation)
    @test simulation.compiled.scenario_plan.authoring.preparation === new_preparation
    @test data.hint_calls[] == 2
    @test model_status(data.model, :leaf).visits == 3
    @test model_status(data.model, :born).visits == 1
end

@testset "alternate compilation has its own owner without taking over the live cache" begin
    data = fixture()
    simulation = run!(data.model; steps=0, outputs=:none)
    canonical = simulation.compiled
    preparation = data.model.scenario_plan_cache
    alternate_specs = (ModelSpec(Probe(Ref(0), Ref(false)); name=:alternate, on=One(id=:leaf)),)
    alternate = Advanced.refresh_bindings!(data.model, alternate_specs)
    @test data.model.binding_cache === canonical
    @test data.model.scenario_plan_cache === preparation
    @test alternate.scenario_plan.authoring.preparation !== preparation
    @test alternate.scenario_plan.authoring.preparation.owner === data.model
    @test alternate.scenario_plan.authoring.preparation.source_specs === alternate_specs
    @test PSE._refresh_runtime_bindings!(data.model, canonical) === canonical
    step!(simulation)
    @test simulation.compiled === canonical
    @test model_status(data.model, :leaf).visits == 1

    copied = deepcopy(data.model)
    copied_preparation = copied.scenario_plan_cache
    @test copied_preparation !== preparation
    @test copied_preparation.owner === copied
    @test copied.binding_cache.scenario_plan.authoring.preparation === copied_preparation
    @test PSE._refresh_runtime_bindings!(copied, copied.binding_cache) === copied.binding_cache
    @test copied_preparation.source_specs !== preparation.source_specs
    @test data.model.scenario_plan_cache === preparation
end

@testset "full configuration invalidation is repaired by the public authoring boundary" begin
    data = fixture()
    simulation = run!(data.model; steps=1, outputs=:none)
    PSE._mark_bindings_dirty!(data.model)
    @test_throws ArgumentError step!(simulation)
    @test model_status(data.model, :leaf).visits == 1
    current = Advanced.refresh_bindings!(data.model; force=true)
    @test data.hint_calls[] == 2
    step!(simulation)
    @test simulation.compiled === current
    @test data.hint_calls[] == 2
    @test model_status(data.model, :leaf).visits == 2
end

@testset "invalid lifecycle cardinality does not replay authored hooks" begin
    for selector in (One(scale=:Leaf), OptionalOne(scale=:Leaf))
        data = fixture(; selector)
        simulation = run!(data.model; steps=0, outputs=:none)
        before = data.hint_calls[]
        register_object!(data.model, Object(:extra; scale=:Leaf, parent=:root))
        message = try
            step!(simulation)
            "no error"
        catch error
            sprint(showerror, error)
        end
        @test occursin("Expected ", message)
        @test occursin("matched_ids=", message)
        @test occursin("requested=", message)
        @test occursin("suggestions=", message)
        @test data.hint_calls[] == before
        @test model_status(data.model, :leaf).visits == 0
    end
end

end
