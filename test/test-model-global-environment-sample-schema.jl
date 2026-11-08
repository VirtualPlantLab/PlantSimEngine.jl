module GlobalEnvironmentSampleSchemaChecks

using Dates
using DataFrames
using PlantSimEngine
using Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

PSE.@process "global_sample_schema_none" verbose=false
PSE.@process "global_sample_schema_probe" verbose=false
PSE.@process "global_sample_schema_owner" verbose=false

struct NoEnvironmentProbe <: AbstractGlobal_Sample_Schema_NoneModel end
PSE.outputs_(::NoEnvironmentProbe) = (visits=0,)
function PSE.run!(::NoEnvironmentProbe, status, environment, constants, context)
    isnothing(environment) || error("Expected the default Nothing environment")
    status.visits += 1
    return nothing
end
struct Probe{T} <: AbstractGlobal_Sample_Schema_ProbeModel
    initial::T
end
PSE.outputs_(model::Probe) = (seen=model.initial, visits=0)
PSE.environment_inputs_(model::Probe) = (T=model.initial,)
function PSE.run!(::Probe, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    return nothing
end
struct Owner{C} <: AbstractGlobal_Sample_Schema_OwnerModel
    capture::C
end
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

# Sampling instrumentation only: the singleton contract still returns exactly
# the authored row. Preparing the schema must never invoke this method.
mutable struct CountedRow{T}
    T::T
    duration::Hour
    reads::Dict{Int,Int}
end
PSE.DataFormat(::Type{<:CountedRow}) = PSE.SingletonAlike()
function PSE._environment_row_at_step(row::CountedRow, step::Int)
    row.reads[step] = get(row.reads, step, 0) + 1
    return row
end

function prepared(source; remap=false, shared=false)
    objects = shared ? (
        Object(:a; scale=:Leaf, kind=:shared),
        Object(:b; scale=:Leaf, kind=:shared),
        Object(:c; scale=:Leaf, kind=:other),
    ) : (Object(:a; scale=:Leaf, kind=:shared),)
    config = remap ? Environment(sources=(T=:T,)) : Environment()
    applications = shared ? (
        ModelSpec(Probe(0f0); name=:probe, on=Many(kind=:shared), environment=config),
        ModelSpec(Probe(0f0); name=:other, on=One(id=:c), environment=config),
    ) : (ModelSpec(Probe(0f0); name=:probe, on=One(id=:a), environment=config),)
    model = CompositeModel(objects...; applications, environment=source)
    simulation = run!(model; steps=0, outputs=:none)
    application = simulation.compiled.applications_by_id[:probe]
    binding = simulation.environment_bindings.by_target[(:probe, ObjectId(:a))]
    return (; model, simulation, application, binding)
end

sample(data, time; environment=PSE._NO_ENVIRONMENT_OVERRIDE) =
    PSE._model_environment_for_binding(data.simulation.environment_bindings,
        data.application, data.binding, time, environment)

@noinline function cached_temperature(data, count)
    total = 0f0
    for _ in 1:count
        total += sample(data, 1).T
    end
    return total
end
cache_hit_allocations(data, count) = @allocated cached_temperature(data, count)

@testset "raw singleton schemas narrow the shared memo without sampling" begin
    model = CompositeModel(Object(:a; scale=:Leaf); applications=(
        ModelSpec(NoEnvironmentProbe(); name=:probe, on=One(id=:a)),))
    simulation = run!(model; steps=0, outputs=:none)
    application = simulation.compiled.applications_by_id[:probe]
    binding = simulation.environment_bindings.by_target[(:probe, ObjectId(:a))]
    @test binding.plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Nothing}
    @test sizeof(binding.plan.sample_schema) == 0
    @test (@inferred PSE._model_environment_for_binding(
        simulation.environment_bindings, application, binding, 1)) === nothing
    @test (@inferred PSE._model_environment_for_binding(
        simulation.environment_bindings, application, binding, 1)) === nothing
    @test haskey(simulation.environment_bindings.sample_cache, (:probe, 1))
    continue!(simulation; steps=1)
    @test final_state(simulation).visits == 1

    source = (T=11.5f0, duration=Hour(1))
    data = prepared(source)
    @test data.binding.plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{typeof(source)}
    @test (@inferred sample(data, 1)) === source
    @test (@inferred sample(data, 1)) === source
    @test data.simulation.environment_bindings.sample_cache isa Dict{Tuple{Symbol,Int},Any}
    for _ in 1:3
        cached_temperature(data, 1000)
        cache_hit_allocations(data, 1000)
    end
    @test cached_temperature(data, 1000) === 11500f0
    @test cache_hit_allocations(data, 1000) == 0
    # A raw default schema must not constrain an explicit override to that
    # source's type or cache its mutable values.
    raw_trial = CountedRow(40.0, Hour(1), Dict{Int,Int}())
    @test sample(data, 1; environment=raw_trial) === raw_trial
    raw_trial.T = 41.0
    @test sample(data, 1; environment=raw_trial).T === 41.0
    @test raw_trial.reads == Dict(1 => 2)
    @test sample(data, 1) === source

    counted = CountedRow(10f0, Hour(1), Dict{Int,Int}())
    shared = prepared(counted; shared=true)
    @test isempty(counted.reads)
    @test shared.binding.plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{typeof(counted)}
    @test sample(shared, 1) === counted
    @test sample(shared, 1) === counted
    sibling = shared.simulation.environment_bindings.by_target[(:probe, ObjectId(:b))]
    @test PSE._model_environment_for_binding(shared.simulation.environment_bindings,
        shared.application, sibling, 1) === counted
    @test counted.reads == Dict(1 => 1)
    other = shared.simulation.compiled.applications_by_id[:other]
    other_binding = shared.simulation.environment_bindings.by_target[(:other, ObjectId(:c))]
    @test PSE._model_environment_for_binding(shared.simulation.environment_bindings,
        other, other_binding, 1) === counted
    @test counted.reads == Dict(1 => 2)
    @test Set(keys(shared.simulation.environment_bindings.sample_cache)) ==
          Set(((:probe, 1), (:other, 1)))
    plans, _ = PSE._compile_environment_application_plans(shared.model,
        shared.simulation.compiled.applications,
        shared.simulation.compiled.applications_by_id; prepare_runtime=false)
    @test all(plan -> plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}, plans)
    @test counted.reads == Dict(1 => 2)
end

@testset "projected histories, resets and explicit trials retain existing memo semantics" begin
    source = CountedRow(10f0, Hour(1), Dict{Int,Int}())
    data = prepared(source; remap=true)
    @test data.binding.plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}
    @test isempty(source.reads)
    @test sample(data, 1).T === 10f0
    source.T = 20f0
    @test sample(data, 3).T === 20f0
    source.T = 30f0
    @test sample(data, 1).T === 10f0
    @test sample(data, 3).T === 20f0
    @test source.reads == Dict(1 => 1, 3 => 1)
    memo = data.simulation.environment_bindings.sample_cache
    @test Set(keys(memo)) == Set(((:probe, 1), (:probe, 3)))

    trial = CountedRow(40f0, Hour(1), Dict{Int,Int}())
    @test sample(data, 1; environment=trial).T === 40f0
    trial.T = 41f0
    @test sample(data, 1; environment=trial).T === 41f0
    @test trial.reads == Dict(1 => 2)
    @test source.reads == Dict(1 => 1, 3 => 1)
    @test memo[(:probe, 1)].T === 10f0
    empty!(memo)
    @test isempty(memo)
    @test sample(data, 1).T === 30f0
    @test source.reads == Dict(1 => 2, 3 => 1)
end

@testset "retained call views preserve captured times across the same shared reset" begin
    capture = Ref{Any}()
    source = CountedRow(10f0, Hour(1), Dict{Int,Int}())
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:owner); applications=(
            ModelSpec(Owner(capture); name=:owner, on=One(id=:owner),
                calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),)),
            ModelSpec(Probe(0f0); name=:leaf, on=One(id=:leaf),
                environment=Environment(sources=(T=:T,))),
        ), environment=source)
    simulation = run!(model; steps=1, outputs=:all)
    first_view = only(call_targets(capture[], :leaf))
    run_call!(first_view; publish=false)
    @test first_view.status.seen === 10f0
    source.T = 20f0
    step!(simulation)
    second_view = only(call_targets(capture[], :leaf))
    run_call!(second_view; publish=false)
    @test second_view.status.seen === 20f0
    source.T = 30f0
    run_call!(first_view; publish=false)
    @test first_view.status.seen === 30f0
    source.T = 40f0
    run_call!(second_view; publish=false)
    @test second_view.status.seen === 20f0
    run_call!(first_view; publish=false)
    @test first_view.status.seen === 30f0
    @test first_view.time == 1 && second_view.time == 2
    @test first_view.environment_bindings.sample_cache ===
          second_view.environment_bindings.sample_cache === simulation.environment_bindings.sample_cache
    step!(simulation)
    run_call!(first_view; publish=false)
    @test first_view.status.seen === 40f0
    @test isempty(outputs(simulation)[(:leaf, ObjectId(:leaf), :seen)])
end

mutable struct SpatialBackend{T} <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,T}
    samples::Int
end
mutable struct SpatialTrial{T}
    values::Dict{Symbol,T}
end
EA.base_step_seconds(::SpatialBackend) = 3600.0
EA.get_nsteps(::SpatialBackend) = 8
EA.environment_variables(::SpatialBackend) = Set((:T,))
EA.bind_environment(::SpatialBackend, object::Object, context, config) =
    (cell=geometry(object).cell,)
function EA.sample(backend::SpatialBackend, handle, ::Symbol, time)
    backend.samples += 1
    return backend.values[handle.cell]
end
function EA.sample(backend::SpatialBackend, handle, trial::SpatialTrial, ::Symbol, time)
    backend.samples += 1
    return trial.values[handle.cell]
end

@testset "spatial and mutable trial sampling bypass the global schema memo" begin
    backend = SpatialBackend(Dict(:a => 10f0, :b => 20f0), 0)
    model = CompositeModel(Object(:leaf; scale=:Leaf, geometry=(cell=:a,));
        applications=(ModelSpec(Probe(0f0); name=:probe, on=One(id=:leaf),
            environment=Environment(provider=:schema_spatial)),), environment=backend)
    simulation = run!(model; steps=0, outputs=:none)
    application = simulation.compiled.applications_by_id[:probe]
    bindings = simulation.environment_bindings
    binding = bindings.by_target[(:probe, ObjectId(:leaf))]
    @test binding.plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}
    read(env=PSE._NO_ENVIRONMENT_OVERRIDE) =
        PSE._model_environment_for_binding(bindings, application, binding, 1, env).T
    @test read() === 10f0
    backend.values[:a] = 11f0
    @test read() === 11f0
    trial = SpatialTrial(Dict(:a => 30f0, :b => 40f0))
    @test read(trial) === 30f0
    trial.values[:a] = 31f0
    @test read(trial) === 31f0
    @test backend.samples == 4
    @test isempty(bindings.sample_cache)
    move_object!(model, :leaf, (cell=:b,))
    refreshed = PSE.Advanced.refresh_environment_bindings!(model, simulation.compiled)
    moved = refreshed.by_target[(:probe, ObjectId(:leaf))]
    @test moved.handle.cell === :b
    @test moved.plan === binding.plan
    @test PSE._model_environment_for_binding(refreshed, application, moved, 1).T === 20f0
    @test PSE._model_environment_for_binding(refreshed, application, moved, 1, trial).T === 40f0
    trial.values[:b] = 41f0
    @test PSE._model_environment_for_binding(refreshed, application, moved, 1, trial).T === 41f0
    @test backend.samples == 7
    @test refreshed.sample_cache === bindings.sample_cache
    @test isempty(refreshed.sample_cache)
end

function table_probe(source; remap=false)
    config = remap ? Environment(sources=(T=:temperature,)) : Environment()
    model = CompositeModel(Object(:a; scale=:Leaf); applications=(
        ModelSpec(Probe(0f0); name=:probe, on=One(id=:a), environment=config),),
        environment=source)
    return run!(model; steps=3, outputs=:all)
end

@testset "DataFrame preparation keeps table samples Any and preserves every Float32 row" begin
    temperatures = Float32[1.25, 2.5, 4]
    unused = Int32[11, 22, 33]
    durations = fill(Hour(1), 3)
    expected = [(1.0, 1.25f0), (2.0, 2.5f0), (3.0, 4f0)]
    for remap in (false, true)
        frame = remap ?
                DataFrame(temperature=copy(temperatures), unused=copy(unused), duration=copy(durations)) :
                DataFrame(T=copy(temperatures), unused=copy(unused), duration=copy(durations))
        rows = remap ?
               [(temperature=temperatures[i], unused=unused[i], duration=durations[i]) for i in 1:3] :
               [(T=temperatures[i], unused=unused[i], duration=durations[i]) for i in 1:3]
        simulation = table_probe(frame; remap)
        control = table_probe(rows; remap)
        plan = simulation.environment_bindings.application_plans_by_id[:probe]
        @test plan.prepared_source isa PSE.PreparedGlobalEnvironmentRows
        @test plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}
        @test current_step(simulation) == current_step(control) == 3
        @test final_state(simulation) == final_state(control) == (seen=4f0, visits=3)
        @test outputs(simulation)[(:probe, ObjectId(:a), :seen)] ==
              outputs(control)[(:probe, ObjectId(:a), :seen)] == expected
        @test all(sample -> sample[2] isa Float32,
            outputs(simulation)[(:probe, ObjectId(:a), :seen)])
        application = simulation.compiled.applications_by_id[:probe]
        binding = simulation.environment_bindings.by_target[(:probe, ObjectId(:a))]
        sampled = PSE._model_environment_for_binding(
            simulation.environment_bindings, application, binding, 2,
        )
        @test sampled.T === 2.5f0
        if !remap
            @test sampled.unused === Int32(22)
            @test sampled.duration == Hour(1)
        end
    end
end

struct ColumnProbe{C} <: AbstractGlobal_Sample_Schema_ProbeModel
    capture::C
end
PSE.outputs_(::ColumnProbe) = (seen=0f0, visits=0)
PSE.environment_inputs_(::ColumnProbe) = (T=Float32[],)
function PSE.run!(model::ColumnProbe, status, environment, constants, context)
    model.capture[] = environment
    status.seen = sum(environment.T)
    status.visits += 1
    return nothing
end

@testset "NamedTuple columns preserve the existing raw singleton contract" begin
    source = (T=Float32[1.25, 2.5, 4], unused=Int32[11, 22, 33], duration=Hour(1))
    capture = Ref{Any}()
    model = CompositeModel(Object(:a; scale=:Leaf); applications=(
        ModelSpec(ColumnProbe(capture); name=:probe, on=One(id=:a)),), environment=source)
    simulation = run!(model; outputs=:all)
    plan = simulation.environment_bindings.application_plans_by_id[:probe]
    @test PSE.DataFormat(source) isa PSE.SingletonAlike
    @test plan.prepared_source === source
    @test plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{typeof(source)}
    @test capture[] === source
    @test current_step(simulation) == 1
    @test final_state(simulation) == (seen=7.75f0, visits=1)
end

struct SamplingRuleSource
    name::Symbol
    visits::Vector{Symbol}
end
Base.Symbol(source::SamplingRuleSource) = (push!(source.visits, source.name); source.name)

@testset "environment rules retain tuple arity and remapping order" begin
    for names in ((:T, :RH, :CO2), [:T, :RH, :CO2])
        visits = Symbol[]
        bindings = (T=(source=SamplingRuleSource(:bound_T, visits),),
            RH=(source=SamplingRuleSource(:bound_RH, visits),))
        sources = (T=SamplingRuleSource(:override_T, visits),
            CO2=SamplingRuleSource(:override_CO2, visits))
        rules = PSE._environment_sampling_rules(bindings, sources, names)
        @test collect(rules) == [:T => :override_T, :RH => :bound_RH, :CO2 => :override_CO2]
        @test visits == [:bound_T, :override_T, :bound_RH, :override_CO2]
        @test eltype(rules) === Pair{Symbol,Symbol}
        @test names isa Tuple ? rules isa Tuple : rules isa Vector
    end
    @test (@inferred PSE._environment_sampling_rules((;), (;), ())) === ()
    @test (@inferred PSE._environment_sampling_rules((;), (;), Symbol[])) == Pair{Symbol,Symbol}[]
    visits = Symbol[]
    unused = (unused=(source=SamplingRuleSource(:not_read, visits),),)
    @test PSE._environment_sampling_rules(unused, (;), ()) === ()
    @test isempty(visits)
end

mutable struct MemoPreparationSource{T}
    T::T
    U::T
    duration::Hour
    sampler_preparations::Int
    source_preparations::Int
end
PSE.DataFormat(::Type{<:MemoPreparationSource}) = PSE.SingletonAlike()
PSE._prepare_environment_sampler(source::MemoPreparationSource) =
    (source.sampler_preparations += 1; nothing)
PSE._prepare_global_environment(source::MemoPreparationSource) =
    (source.source_preparations += 1; source)

function memo_source_model(source)
    return CompositeModel(Object(:a; scale=:Leaf), Object(:b; scale=:Leaf);
        applications=(
            ModelSpec(Probe(0f0); name=:raw, on=One(id=:a)),
            ModelSpec(Probe(0f0); name=:mapped, on=One(id=:b),
                environment=Environment(sources=(T=:U,)))), environment=source)
end
memo_preparations(source) = (source.sampler_preparations, source.source_preparations)

@testset "source-plan memo shares preparation and preserves current application metadata" begin
    observed_source = MemoPreparationSource(10f0, 20f0, Hour(1), 0, 0)
    observed = run!(memo_source_model(observed_source); steps=0, outputs=:none)
    schema = PSE._environment_plan_schema_from_types(typeof.(observed.environment_bindings.application_plans))
    for fixed in (false, true)
        source = MemoPreparationSource(10f0, 20f0, Hour(1), 0, 0)
        model = memo_source_model(source)
        simulation = PSE._prepare_simulation!(model; steps=0, outputs=:none,
            constants=PSE.Constants(), environment_plan_schema=fixed ? schema : nothing)
        compiled, owner = simulation.compiled, simulation.environment_bindings
        @test memo_preparations(source) == (1, 1)
        raw, mapped = owner.application_plans_by_id[:raw], owner.application_plans_by_id[:mapped]
        @test raw.application_id === :raw && mapped.application_id === :mapped
        @test raw.prepared_source === mapped.prepared_source === source
        @test raw.sampler === mapped.sampler === nothing
        @test raw.sampling_rules == (:T => :T,)
        @test mapped.sampling_rules == (:T => :U,)
        @test raw.uses_raw_global_source && !mapped.uses_raw_global_source
        @test raw.sample_schema isa PSE.GlobalEnvironmentSampleSchema{typeof(source)}
        @test mapped.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}
        current, by_id = PSE._compile_environment_application_plans(model,
            compiled.applications, compiled.applications_by_id;
            previous_plans_by_id=owner.application_plans_by_id,
            plan_schema=owner.application_plan_schema)
        @test memo_preparations(source) == (1, 1)
        @test map(plan -> plan.application_id, current) == [:raw, :mapped]
        for original in (raw, mapped)
            reused = by_id[original.application_id]
            @test reused.sampler === original.sampler
            @test reused.prepared_source === original.prepared_source
            @test reused.config === original.config
            @test reused.compiled_sampling_rules === original.compiled_sampling_rules
            @test reused.sample_schema === original.sample_schema
        end
        disabled, _ = PSE._compile_environment_application_plans(model,
            compiled.applications, compiled.applications_by_id;
            previous_plans_by_id=owner.application_plans_by_id, prepare_runtime=false)
        @test memo_preparations(source) == (1, 1)
        @test all(plan -> isnothing(plan.sampler) && isnothing(plan.prepared_source) &&
            plan.sample_schema isa PSE.GlobalEnvironmentSampleSchema{Any}, disabled)
        for (id, object_id, expected) in ((:raw, :a, 11f0), (:mapped, :b, 21f0))
            source.T, source.U = 11f0, 21f0
            application = compiled.applications_by_id[id]
            binding = owner.by_target[(id, ObjectId(object_id))]
            @test PSE._model_environment_for_binding(owner, application, binding, 1, source).T === expected
            source.T, source.U = 12f0, 22f0
            @test PSE._model_environment_for_binding(owner, application, binding, 1, source).T === expected + 1f0
        end
        @test memo_preparations(source) == (1, 1)
        if fixed
            @test all(plan -> PSE._with_environment_plan(identity, schema, plan) === plan, current)
            mapped_schema = PSE._environment_plan_schema_from_types([typeof(mapped)])
            @test_throws "raw` is outside its prepared family schema" PSE._refresh_environment_bindings!(
                model, compiled, owner; plan_schema=mapped_schema)
            @test model.environment_binding_cache === owner
            alternate = PSE.Advanced.compile_composite_model(model, (model.applications[2],))
            replacement = PSE._refresh_environment_bindings!(model, alternate, owner;
                plan_schema=mapped_schema)
            @test replacement.application_plan_schema === mapped_schema
            @test only(replacement.application_plans).application_id === :mapped
            @test memo_preparations(source) == (2, 2)
            again, _ = PSE._compile_environment_application_plans(model,
                alternate.applications, alternate.applications_by_id;
                previous_plans_by_id=replacement.application_plans_by_id,
                plan_schema=replacement.application_plan_schema)
            @test only(again).prepared_source === source
            @test memo_preparations(source) == (2, 2)
        end
    end
end

@testset "previous source plans retain the last sampler and prepared-source pair" begin
    weather = PSE.PlantMeteo.Weather([
        PSE.PlantMeteo.Atmosphere(date=DateTime(2025, 1, 1), T=10.0,
            Wind=1.0, Rh=0.5, duration=Hour(1)),
        PSE.PlantMeteo.Atmosphere(date=DateTime(2025, 1, 1, 1), T=20.0,
            Wind=1.0, Rh=0.5, duration=Hour(1))])
    for source in (DataFrame(T=Float32[10, 20], duration=fill(Hour(1), 2)), weather)
        data = prepared(source; shared=true)
        compiled, owner = data.simulation.compiled, data.simulation.environment_bindings
        fresh, fresh_by_id = PSE._compile_environment_application_plans(data.model,
            compiled.applications, compiled.applications_by_id)
        initial = owner.application_plans_by_id[:probe]
        newer = fresh_by_id[:other]
        if source isa DataFrame
            @test initial.prepared_source.rows !== newer.prepared_source.rows
        else
            @test initial.sampler !== newer.sampler
        end
        previous = Dict(:initial => initial, :newer => newer)
        expected = last(collect(values(previous)))
        for schema in (nothing, PSE._environment_plan_schema_from_types(typeof.(fresh)))
            reused, _ = PSE._compile_environment_application_plans(data.model,
                compiled.applications, compiled.applications_by_id;
                previous_plans_by_id=previous, plan_schema=schema)
            @test map(plan -> plan.application_id, reused) == [:probe, :other]
            @test all(plan -> plan.sampler === expected.sampler, reused)
            @test all(plan -> plan.prepared_source === expected.prepared_source, reused)
        end
    end
end

end # module GlobalEnvironmentSampleSchemaChecks
