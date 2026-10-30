module SharedPlanPrototypeChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "shared_plan_probe" verbose=false
PSE.@process "shared_plan_parent_probe" verbose=false
PSE.@process "shared_plan_temporal_probe" verbose=false

struct Probe{T,C} <: AbstractShared_Plan_ProbeModel
    gain::T
    contexts::C
end
PSE.inputs_(::Probe) = (driver=Default(1.0),)
PSE.outputs_(::Probe) = (value=0.0,)
function PSE.run!(model::Probe, status, environment, constants, context)
    push!(model.contexts, context)
    status.value += model.gain * status.driver
    return nothing
end

struct ParentProbe <: AbstractShared_Plan_Parent_ProbeModel end
PSE.outputs_(::ParentProbe) = (total=0.0,)
function PSE.run!(::ParentProbe, status, environment, constants, context)
    targets = run_call!(context, :children; publish=true)
    status.total = sum(target.status.value for target in targets)
    return nothing
end

struct TemporalProbe <: AbstractShared_Plan_Temporal_ProbeModel end
PSE.inputs_(::TemporalProbe) = (previous=Required(Float64),)
PSE.outputs_(::TemporalProbe) = (observed=0.0,)
function PSE.run!(::TemporalProbe, status, environment, constants, context)
    status.observed = status.previous
    return nothing
end

function fixture(; parent=false, temporal=false)
    contexts = Any[]
    external = [2.0]
    objects = Object[
        Object(:plant; scale=:Plant,
            status=temporal ? Status(previous=0.0) : nothing),
        Object(:leaf_a; scale=:Leaf, parent=:plant,
            status=Status((driver=Ref(external, 1),))),
        Object(:leaf_b; scale=:Leaf, parent=:plant),
    ]
    applications = ModelSpec[
        ModelSpec(Probe(2.0, contexts); name=:source, on=Many(scale=:Leaf)),
    ]
    if parent
        push!(applications, ModelSpec(ParentProbe(); name=:parent,
            on=One(id=:plant), calls=(children=Many(scale=:Leaf,
                within=Subtree(), application=:source),)))
    elseif temporal
        push!(applications, ModelSpec(TemporalProbe(); name=:temporal,
            on=One(id=:plant), inputs=(previous=One(id=:leaf_a,
                within=Subtree(), application=:source, var=:value,
                policy=PreviousTimeStep(:previous)),)))
    end
    model = CompositeModel(objects...; applications,
        environment=(duration=Hour(1),))
    return (; model, external, contexts)
end

prepare(f; narrow_status=false, local_context=false) =
    PSE._with_execution_policy(; narrow_status, local_context, shared_plans=true) do
        run!(f.model; steps=0, outputs=:all)
    end

@testset "compact shared root rows preserve aliases, context identity and refresh" begin
    for narrow_status in (false, true), local_context in (false, true)
        f = fixture()
        sim = prepare(f; narrow_status, local_context)
        counts = PSE._execution_strategy_counts(sim)
        @test counts.shared_targets == 2
        @test counts.rich_targets == 0
        @test counts.shared_plans == 1
        @test counts.root_call_caches == 0
        # RefArray and RefValue inputs can require distinct concrete batches.
        # Sharing the model descriptor must work across both representations.
        rows = [target for batch in sim.execution_plan.batches for target in batch.targets]
        @test hasproperty(rows[1], :model)
        @test hasproperty(rows[1], :kernel_status)
        @test rows[1].plan === rows[2].plan
        @test rows[1].context !== rows[2].context
        @test rows[1].canonical_status === model_status(f.model, :leaf_a)
        @test rows[1].status === rows[1].canonical_status
        @test sum(row.batch_size for row in PSE.Diagnostics.explain_execution_plan(sim)) == 2

        # Continue outside the policy scope: the prepared plan owns its choice.
        step!(sim)
        @test final_state(sim, :leaf_a).value == 4.0
        @test final_state(sim, :leaf_b).value == 2.0
        @test f.contexts[1] !== f.contexts[2]
        @test f.contexts[1].object_id == ObjectId(:leaf_a)
        @test f.contexts[2].object_id == ObjectId(:leaf_b)
        f.external[1] = 3.0
        step!(sim)
        @test final_state(sim, :leaf_a).value == 10.0
        @test PSE.refvalue(model_status(f.model, :leaf_a), :driver) isa Base.RefArray

        register_object!(f.model, Object(:leaf_c; scale=:Leaf, parent=:plant))
        step!(sim)
        counts = PSE._execution_strategy_counts(sim)
        @test counts.shared_targets == 3
        @test counts.shared_plans == 1
        @test final_state(sim, :leaf_c).value == 2.0
        @test length(collect_outputs(sim; sink=nothing)) > 0
    end
end

@testset "call-owned and temporal state retain their complete execution strategy" begin
    f = fixture(parent=true)
    sim = prepare(f)
    @test PSE._execution_strategy_counts(sim).rich_targets == 1
    step!(sim)
    @test final_state(sim, :plant).total == 6.0
    @test length(f.contexts) == 2

    f = fixture(temporal=true)
    sim = prepare(f)
    counts = PSE._execution_strategy_counts(sim)
    @test counts.shared_targets == 2
    @test counts.rich_targets == 1
    @test get(counts.rich_reasons, :temporal_inputs, 0) == 1
    step!(sim)
    step!(sim)
    @test final_state(sim, :plant).observed == 4.0
end

@testset "retiring a model's last target releases its shared-plan index entry" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:a; scale=:Leaf, parent=:plant),
        Object(:b; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(Probe(1.0, Any[]); name=:a, on=Many(id=:a)),
            ModelSpec(Probe(2.0, Any[]); name=:b, on=Many(id=:b)),
        ),
        environment=(duration=Hour(1),),
    )
    sim = PSE._with_execution_policy(shared_plans=true) do
        run!(model; steps=1, outputs=:all)
    end
    @test PSE._execution_strategy_counts(sim).shared_plans == 2
    remove_object!(model, :b)
    step!(sim)
    @test PSE._execution_strategy_counts(sim).shared_plans == 1
    @test PSE._execution_strategy_counts(sim).shared_targets == 1
    @test final_state(sim, :a).value == 2.0
    @test last.(outputs(sim)[(:b, ObjectId(:b), :value)]) == [2.0]
end

end
