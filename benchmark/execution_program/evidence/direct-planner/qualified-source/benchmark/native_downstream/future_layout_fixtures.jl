module FutureLayoutFixtures

using Dates, Random, PlantSimEngine
const PSE=PlantSimEngine
const EA=PSE.EnvironmentAPI

export generic_future_fixture, fixture_guard, model_rng_fingerprint, task_rng_state,
    preserve_task_rng, generic_observations, portable_snapshot, downstream_future_fixture

mutable struct KernelProbe
    creator_calls::Int
    worker_calls::Int
    child_calls::Int
    record_types::Bool
    observations::Vector{Any}
end
KernelProbe(record_types=false)=KernelProbe(0,0,0,record_types,Any[])

mutable struct ProbeEnvironment <: EA.AbstractEnvironmentBackend
    gain::Float32
    samples::Int
    binds::Int
end
EA.base_step_seconds(::ProbeEnvironment)=3600.0
EA.get_nsteps(::ProbeEnvironment)=8
EA.environment_variables(::ProbeEnvironment)=Set((:gain,))
function EA.bind_environment(environment::ProbeEnvironment,object::PSE.Object,context,config)
    environment.binds+=1
    return (id=object.id.value,)
end
function EA.sample(environment::ProbeEnvironment,handle,variable::Symbol,time)
    variable===:gain || error("Unexpected generic future variable")
    environment.samples+=1
    return environment.gain
end

PSE.@process "future_layout_creator" verbose=false
PSE.@process "future_layout_worker" verbose=false
PSE.@process "future_layout_child" verbose=false
struct FutureCreator <: AbstractFuture_Layout_CreatorModel
    limit::Int
    probe::KernelProbe
end
struct FutureWorker{T,R} <: AbstractFuture_Layout_WorkerModel
    weight::T
    rng::R
    probe::KernelProbe
end
struct FutureChild{T,R} <: AbstractFuture_Layout_ChildModel
    weight::T
    rng::R
    probe::KernelProbe
end
PSE.inputs_(::FutureCreator)=NamedTuple()
PSE.outputs_(::FutureCreator)=(births=0,)
PSE.inputs_(::FutureWorker)=NamedTuple()
PSE.outputs_(::FutureWorker{T}) where {T}=(value=zero(T),worker_visits=0)
PSE.environment_inputs_(::FutureWorker{T}) where {T}=(gain=zero(T),)
PSE.dep(::FutureWorker)=(child=PSE.Call(PSE.One(within=PSE.Self(),
    process=:future_layout_child)),)
PSE.inputs_(::FutureChild)=NamedTuple()
PSE.outputs_(::FutureChild{T}) where {T}=(child_value=zero(T),child_visits=0)
PSE.environment_inputs_(::FutureChild{T}) where {T}=(gain=zero(T),)

Base.@nospecializeinfer @noinline function _observe!(probe,model,status,environment,constants,context)
    @nospecialize model status environment constants context
    probe.record_types || return nothing
    signature=Tuple{typeof(PSE.run!),typeof(model),typeof(status),typeof(environment),
        typeof(constants),typeof(context)}
    references=Dict{Symbol,Any}(name=>PSE.refvalue(status,name)
        for name in propertynames(status))
    push!(probe.observations,(application=context.application.id,
        object_id=context.object_id,signature,references))
    return nothing
end

_unit(id)=PSE.Object(id;kind=:future_unit,parent=0,
    status=(value=0.0f0,worker_visits=0,child_value=0.0f0,child_visits=0))
function PSE.run!(model::FutureCreator,status,environment,constants,context)
    model.probe.creator_calls+=1
    _observe!(model.probe,model,status,environment,constants,context)
    status.births>=model.limit && return nothing
    status.births+=1
    PSE.register_object!(PSE.runtime_model(context),_unit(status.births))
    return nothing
end
function PSE.run!(model::FutureWorker,status,environment,constants,context)
    model.probe.worker_calls+=1
    _observe!(model.probe,model,status,environment,constants,context)
    status.value+=model.weight*environment.gain+rand(model.rng,Float32)
    status.worker_visits+=1
    PSE.run_call!(context,:child;publish=true)
    return nothing
end
function PSE.run!(model::FutureChild,status,environment,constants,context)
    model.probe.child_calls+=1
    _observe!(model.probe,model,status,environment,constants,context)
    status.child_value+=model.weight*environment.gain+rand(model.rng,Float32)
    status.child_visits+=1
    return nothing
end

function _generic_model(;nfuture=0,record_types=false,seed=1)
    probe=KernelProbe(record_types)
    environment=ProbeEnvironment(2.0f0,0,0)
    model=PSE.CompositeModel(PSE.Object(0),(_unit(index) for index in 1:nfuture)...;
        applications=(
            PSE.ModelSpec(FutureCreator(2,probe);name=:creator,on=PSE.One(id=0),every=Hour(1)),
            PSE.ModelSpec(FutureWorker(1.0f0,MersenneTwister(seed),probe);
                name=:worker,on=PSE.Many(kind=:future_unit),every=Hour(1)),
            PSE.ModelSpec(FutureChild(3.0f0,MersenneTwister(seed+1),probe);
                name=:child,on=PSE.Many(kind=:future_unit),every=Hour(1)),
        ),environment)
    return (;model,probe,environment)
end

"""Explicit future archetype; no scientific kernel or early growth step is used.

Live starts with zero worker/child targets. Its first two steps register one then
two Float32 organs. The disposable builder independently instantiates exactly
those declared fields/models and a separate backend/RNG/probe for layout work.
"""
function generic_future_fixture(;steps=2,seed=1,record_types=false)
    steps in (1,2) || throw(ArgumentError("The tiny generic fixture supports one/two steps"))
    live=_generic_model(;nfuture=0,record_types,seed)
    builder=()->_generic_model(;nfuture=2,record_types=false,seed).model
    environment_types=Dict{Any,Any}(
        :creator=>NamedTuple{(),Tuple{}},
        :worker=>typeof((gain=0.0f0,)),:child=>typeof((gain=0.0f0,)))
    return (;live...,future_builder=builder,environment_types,steps,
        package=:generic,expected_targetless=(:worker,:child),
        explicit_future_objects=2)
end

task_rng_state()=(default=copy(Random.default_rng()),seed=copy(Random.get_tls_seed()))
function preserve_task_rng(f)
    destination=Random.default_rng()
    saved=copy(destination)
    seed_destination=Random.get_tls_seed()
    saved_seed=copy(seed_destination)
    try
        return f()
    finally
        copy!(destination,saved)
        copy!(seed_destination,saved_seed)
    end
end

"""Read future draws from independent copies; never advance scientific RNGs."""
Base.@nospecializeinfer @noinline function model_rng_fingerprint(model)
    @nospecialize model
    rows=Any[]
    for (index,spec) in pairs(model.applications)
        application_model=getproperty(spec,:model)
        for name in (:rng,:random_generator)
            hasproperty(application_model,name) || continue
            rng=getproperty(application_model,name)
            rng isa Random.AbstractRNG || continue
            push!(rows,(application=spec.name,slot=index,field=name,
                next_draws=rand(copy(rng),UInt64,4)))
        end
    end
    return rows
end

Base.@nospecializeinfer @noinline function fixture_guard(fixture)
    @nospecialize fixture
    probe=hasproperty(fixture,:probe) ? fixture.probe : nothing
    calls=probe===nothing ? nothing : (creator=probe.creator_calls,
        worker=probe.worker_calls,child=probe.child_calls)
    samples=fixture.environment isa ProbeEnvironment ? fixture.environment.samples : nothing
    return (kernel_calls=calls,samples,
        model_rngs=model_rng_fingerprint(fixture.model))
end
generic_observations(fixture)=hasproperty(fixture,:probe) ? copy(fixture.probe.observations) : Any[]

# PB scientific methods are never wrapped. This controller does lifecycle work
# only, on generic object labels; the same original models remain responsible
# for every numerical state transition after each birth.
struct PBGrowthCreator <: AbstractFuture_Layout_CreatorModel
    limit::Int
    probe::KernelProbe
end
PSE.inputs_(::PBGrowthCreator)=NamedTuple()
PSE.outputs_(::PBGrowthCreator)=(births=0,)
_pb_unit(id)=PSE.Object(id;kind=:gas_exchange_unit,scale=:diagnostic_unit,parent=0,
    status=(Ra_SW_f=150.0+mod(id,7),sky_fraction=0.8,
        aPPFD=(150.0+mod(id,7))*0.48*4.57,d=0.03))
function PSE.run!(model::PBGrowthCreator,status,environment,constants,context)
    model.probe.creator_calls+=1
    _observe!(model.probe,model,status,environment,constants,context)
    status.births>=model.limit && return nothing
    status.births+=1
    PSE.register_object!(PSE.runtime_model(context),_pb_unit(status.births))
    return nothing
end

# These fixed forcing fixtures use the ordinary untransformed global row.
# Reading its stored first row is type declaration, never backend sampling or
# model execution. PB's 1:1 Weather fast path uses its original Atmosphere row;
# XP's DataFrame provider uses the prepared concrete NamedTuple row.
Base.@nospecializeinfer @noinline function _global_row_types(model)
    @nospecialize model
    source=PSE._prepare_global_environment(model.environment)
    row=PSE._environment_row_at_step(source,1)
    return Dict{Any,Any}(spec.name=>typeof(row) for spec in model.applications)
end
Base.@nospecializeinfer @noinline function _pb_growth_model(;steps=2,nfuture=0,record_types=false)
    isdefined(Main,:NativePBDriver) || error("Load pb_driver.jl before the PB future fixture")
    source=Base.invokelatest(getfield(Main,:NativePBDriver).pb_native_fixture;
        native=false,nobjects=1,steps)
    probe=KernelProbe(record_types)
    applications=(PSE.ModelSpec(PBGrowthCreator(2,probe);name=:creator,
        on=PSE.One(id=0),every=Hour(1)),source.model.applications...)
    model=PSE.CompositeModel(PSE.Object(0),(_pb_unit(index) for index in 1:nfuture)...;
        applications,environment=source.model.environment)
    return (;model,probe,environment=model.environment)
end

Base.@nospecializeinfer @noinline function _xp_base_model(;steps=4,seed=1)
    isdefined(Main,:NativeXPDriver) || error("Load xpalm_driver.jl before the XP future fixture")
    return Base.invokelatest(getfield(Main,:NativeXPDriver).xpalm_native_fixture;
        steps,seed,native=false)
end

"""Construct only the explicitly known next Phytomer/Internode/Leaf metadata.

No PhytomerEmission, run_call!, initializer, growth, sex or architecture kernel
is called here. This finite declaration intentionally does not predict future
Male/Female layouts or transient targeted-initializer schemas. It uses the same
public add_organ! status adapter and initial-status order as PhytomerEmission.
"""
Base.@nospecializeinfer @noinline function _xp_future_model(;steps=4,seed=1)
    model=Base.invokelatest(_xp_base_model;steps,seed)
    phytomers=PSE.model_objects(model;scale=:Phytomer)
    isempty(phytomers) && error("XP fixture has no Phytomer parent")
    sort!(phytomers;by=object->object.id.value)
    parent=PSE.source_node(model,last(phytomers).id)
    index=length(phytomers)+1
    phytomer=PSE.add_organ!(parent,model,:<,:Phytomer,3;index,
        attributes=Dict{Symbol,Any}(),initial_status=(plant_age=1,initiation_age=1))
    phyto_node=PSE.source_node(model,PSE.object_id(model,phytomer))
    internode=PSE.add_organ!(phyto_node,model,:/,:Internode,4;index,
        attributes=Dict{Symbol,Any}(),initial_status=(plant_age=1,initiation_age=1))
    internode_node=PSE.source_node(model,PSE.object_id(model,internode))
    PSE.add_organ!(internode_node,model,:+,:Leaf,4;index,
        attributes=Dict{Symbol,Any}(),initial_status=(plant_age=1,initiation_age=1))
    return model
end

"""Small original-package fixtures with independent metadata-only archetypes.

PB has zero initial numerical targets and two known future objects. XP declares
only the first next three-organ archetype; type coverage may be incomplete and
is measured after execution. Future discovery never advances either timeline.
"""
Base.@nospecializeinfer @noinline function downstream_future_fixture(kind::Symbol;
    steps=kind===:xp ? 4 : 2,seed=1,record_types=false)
    if kind===:pb
        steps in (1,2) || throw(ArgumentError("PB growth pilot supports one/two steps"))
        live=Base.invokelatest(_pb_growth_model;steps,nfuture=0,record_types)
        builder=()->Base.invokelatest(_pb_growth_model;steps,nfuture=2).model
        return (;live...,future_builder=builder,
            environment_types=Base.invokelatest(_global_row_types,live.model),steps,
            package=:pb,expected_targetless=(:energy,:photosynthesis,:stomata),
            explicit_future_objects=2,initial_ids=PSE.object_ids(live.model),
            observed_kernel_scope=:lifecycle_controller_only_original_PB_methods_unwrapped)
    elseif kind===:xp
        model=Base.invokelatest(_xp_base_model;steps,seed)
        builder=()->preserve_task_rng(()->Base.invokelatest(_xp_future_model;steps,seed))
        return (;model,environment=model.environment,future_builder=builder,
            environment_types=Base.invokelatest(_global_row_types,model),steps,
            package=:xp,expected_targetless=(),explicit_future_objects=3,
            initial_ids=PSE.object_ids(model),
            observed_kernel_scope=:original_XP_methods_unwrapped_no_entry_signature_claim)
    end
    throw(ArgumentError("Unknown downstream future fixture: $kind"))
end

Base.@nospecializeinfer @noinline function portable_snapshot(simulation;kind=:generic)
    @nospecialize simulation
    scientific=if kind===:xp
        getfield(Main,:NativeXPDriver).xp_portable_snapshot(simulation)
    else
        states=sort!([(id=repr(object.id.value),fields=sort!([
            (name=string(name),type=string(typeof(value)),value=repr(value))
            for (name,value) in pairs(PSE.final_state(simulation,object.id))];by=row->row.name))
            for object in PSE.model_objects(simulation.model)];by=row->row.id)
        history=sort!([(key=repr(key),samples=[
            (time=first(sample),type=string(typeof(last(sample))),value=repr(last(sample)))
            for sample in stream]) for (key,stream) in pairs(PSE.outputs(simulation))];by=row->row.key)
        (;step=PSE.current_step(simulation),states,history)
    end
    topology=sort!([(id=repr(object.id.value),parent=repr(object.parent),
        kind=repr(object.kind),scale=repr(object.scale),geometry=repr(PSE.geometry(object)))
        for object in PSE.model_objects(simulation.model)];by=row->row.id)
    return (;scientific,topology)
end

end
