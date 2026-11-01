module CoupledQualification

using Dates, SHA, Test, PlantSimEngine
import AMAPSim, ArchimedLight, PlantBiophysics, PlantGeom
const PSE=PlantSimEngine

function _checked_package_root(package,variable)
    actual=realpath(pkgdir(package))
    expected=get(ENV,variable,actual)
    realpath(expected)==actual || error("Loaded $(nameof(package)) is not the frozen $variable checkout")
    return actual
end
const AMAP_ROOT=_checked_package_root(AMAPSim,"PSE_AMAPSIM_PATH")
const ARCHIMED_ROOT=_checked_package_root(ArchimedLight,"PSE_ARCHIMEDLIGHT_PATH")
const PB_ROOT=_checked_package_root(PlantBiophysics,"PSE_PLANTBIOPHYSICS_PATH")
const ORIGINAL_BENCHMARK=joinpath(AMAP_ROOT,"benchmark","native_physiology_benchmark.jl")
include(ORIGINAL_BENCHMARK)
const Benchmark=NativePhysiologyBenchmark
const Example=Benchmark.Example
const Native=Example.Native
const Adapter=Example.Adapter
const Physiology=Example.Physiology

export config,construct,fingerprint,work,packages,check,identities,
    same_identity_transitions,source_paths,source_manifest,nested_clocks,
    EXCLUDED_CLOCK_OUTPUTS

# Qualified names only. In particular physical_time_seconds,
# duration_seconds and preceding_interval_seconds remain scientific state.
const EXCLUDED_CLOCK_OUTPUTS=((:native_radiation,:geometry_seconds),
    (:native_radiation,:light_seconds))
_is_clock(application,variable)=(application,variable) in EXCLUDED_CLOCK_OUTPUTS

function config(;profile=:rauh,steps=2,horizon=0.5*steps,outputs=:all,seed=1,
    initial_reserve_gC=1.0)
    profile in (:rauh,:merisier) || throw(ArgumentError("Expected original :rauh or :merisier profile"))
    steps isa Integer && 1<=steps<=4 || throw(ArgumentError("Initial qualification is bounded to one through four intervals"))
    horizon isa Real && isfinite(horizon) && 0<horizon<=2 || throw(ArgumentError("Expected positive horizon <=2"))
    return (;kind=:coupled,profile,steps=Int(steps),horizon,outputs,seed,
        initial_reserve_gC,original_benchmark=ORIGINAL_BENCHMARK,
        scope=:original_headless_native_ArchimedLight_Fvcb_Medlyn_carbon_growth)
end

Base.@nospecializeinfer @noinline function construct(config)
    @nospecialize config
    setup=Base.invokelatest(Example.scenario,config.profile;steps=config.steps,
        horizon=config.horizon,seed=config.seed,initial_reserve_gC=config.initial_reserve_gC)
    model=setup.model
    return (;setup...,initial_ids=collect(PSE.object_ids(model)),
        constants=PSE.PlantMeteo.Constants(),package=:coupled,
        initial_native_organs=length(Adapter.native_state(model,setup.plant.id).native.plant.organs))
end

packages()=(PSE,AMAPSim,ArchimedLight,PlantBiophysics,PlantGeom,PSE.PlantMeteo)

"""Exact value graph with deterministic mutable-alias labels, not object addresses.

The sole native address-valued ownership token is compared to its actual owner
and represented by that logical plant identity. All other native fields,
physical clocks, numerical types, array shapes, RNG words and event queues are
retained. Unsupported pointer/task resources fail rather than disappearing.
"""
mutable struct SnapshotContext
    seen::IdDict{Any,Int}
    clock_owners::IdDict{Any,Any}
end
SnapshotContext()=SnapshotContext(IdDict{Any,Int}(),IdDict{Any,Any}())
function _context(fixture)
    context=SnapshotContext()
    state=Adapter.native_state(fixture.model,fixture.plant.id)
    state.development===nothing ||
        (context.clock_owners[state.development]=(plant=state.native.plant,id=state.plant_id))
    return context
end
Base.@nospecializeinfer @noinline function _type_name(type)::String
    @nospecialize type
    # The opt-in task-local cache belongs to one complete diagnostic invocation.
    # It holds immutable type/module names, never model values or memberships.
    names=get(task_local_storage(),:pse_coupled_qualification_type_names,nothing)
    names===nothing && return string(type)
    return get!(names,type) do
        string(type)
    end
end
Base.@nospecializeinfer @noinline function _value(value,context::SnapshotContext)
    @nospecialize value
    value===nothing && return nothing
    value===missing && return (type=:Missing,)
    value isa Union{Symbol,AbstractString} && return value
    value isa Number && return (type=_type_name(typeof(value)),value=repr(value))
    value isa Enum && return (type=_type_name(typeof(value)),value=Int(value))
    value isa Union{Type,Module} && return (type=_type_name(typeof(value)),value=_type_name(value))
    value isa Union{Task,Channel,Ptr} && error("Unsupported resource in scientific snapshot: $(typeof(value))")
    value isa NamedTuple && return NamedTuple{keys(value)}(map(x->_value(x,context),values(value)))
    value isa Tuple && return map(x->_value(x,context),value)
    T=typeof(value)
    tracked=ismutabletype(T)
    if tracked && haskey(context.seen,value)
        return (alias=context.seen[value],)
    end
    label=tracked ? length(context.seen)+1 : nothing
    tracked && (context.seen[value]=label)
    contents=if value isa AbstractDict
        [(key=_value(key,context),value=_value(value[key],context))
            for key in sort!(collect(keys(value));by=repr)]
    elseif value isa AbstractSet
        [_value(item,context) for item in sort!(collect(value);by=repr)]
    elseif value isa AbstractArray
        if eltype(value)<:Number && isprimitivetype(eltype(value))
            # Exact scientific data, compacted only in the untimed snapshot.
            # Dense logical column order also covers views and empty/0-D arrays.
            # Restrict primitive numbers to avoid padding in arbitrary structs.
            bytes=reinterpret(UInt8,vec(Array(value)))
            (element_type=_type_name(eltype(value)),shape=size(value),
                payload=(encoding=:column_major_native_bytes_hex,
                    byte_order=Base.ENDIAN_BOM==0x04030201 ? :little : :big,
                    data=bytes2hex(bytes)))
        else
            (element_type=_type_name(eltype(value)),shape=size(value),
                values=[_value(item,context) for item in value])
        end
    elseif haskey(context.clock_owners,value)
        owner=context.clock_owners[value]
        NamedTuple{fieldnames(T)}(Tuple(name===:plant_identity ?
            (logical_plant=_value(owner.id,context),
                matches_owning_native_plant=getfield(value,name)==objectid(owner.plant)) :
            _value(getfield(value,name),context) for name in fieldnames(T)))
    else
        NamedTuple{fieldnames(T)}(Tuple(_value(getfield(value,name),context) for name in fieldnames(T)))
    end
    return (type=_type_name(T),alias=label,contents=contents)
end

_objects(model)=sort!(collect(PSE.model_objects(model));by=object->repr(object.id.value))
function _scene_object(model)
    return only(PSE.model_objects(model;scale=:Scene))
end
function _status_snapshot(object,scene_id,context)
    return [(name=name,type=_type_name(typeof(getproperty(object.status,name))),
        value=object.id==scene_id && _is_clock(:native_radiation,name) ?
            (excluded_clock=(:native_radiation,name),) :
            _value(getproperty(object.status,name),context))
        for name in sort!(collect(propertynames(object.status));by=string)]
end
function _history(simulation,context)
    return [(key=_value(key,context),samples=[
        (time=_value(first(sample),context),value=_is_clock(key[1],key[3]) ?
            (excluded_clock=(key[1],key[3]),value_type=string(typeof(last(sample)))) :
            _value(last(sample),context)) for sample in stream])
        for (key,stream) in sort!(collect(pairs(PSE.outputs(simulation)));by=pair->repr(first(pair)))]
end

"""Portable complete scientific state; no timer or diagnostic traversal enters clocks.

The opening light scene is physical geometry (including mesh, source owners and
MTG), not the opaque ArchimedLight solver/cache object. The complete native state
contains committed organ geometry as well as potential/realized growth arrays.
"""
function fingerprint(simulation,fixture,config)
    context=_context(fixture)
    scene=_scene_object(fixture.model)
    objects=[(id=_value(object.id,context),parent=_value(object.parent,context),
        children=_value(object.children,context),
        name=object.name,kind=object.kind,scale=object.scale,species=object.species,
        geometry=_value(PSE.geometry(object),context),
        status=_status_snapshot(object,scene.id,context)) for object in _objects(fixture.model)]
    return (step=PSE.current_step(simulation),objects=objects,
        native=_value(Adapter.native_state(fixture.model,fixture.plant.id),context),
        opening_radiative_geometry=_value(fixture.radiation.last_scene,context),
        history=_history(simulation,context),
        normalization=(excluded_clock_outputs=EXCLUDED_CLOCK_OUTPUTS,
            address_tokens=:LocalDevelopment_plant_identity_checked_against_logical_owner,
            backend_cache=:not_scientific_state_physical_scene_retained))
end

function identities(model)
    statuses=Dict{Any,Any}();references=Dict{Any,Any}();aliases=IdDict{Any,Int}()
    alias_signature=Any[]
    for object in _objects(model)
        statuses[object.id]=object.status
        for name in sort!(collect(propertynames(object.status));by=string)
            reference=PSE.refvalue(object.status,name)
            references[(object.id,name)]=reference
            label=get!(aliases,reference,length(aliases)+1)
            push!(alias_signature,(object.id,name,string(typeof(reference)),label))
        end
    end
    return (;statuses,references,alias_signature)
end
function same_identity_transitions(old_left,old_right,new_left,new_right)
    keys(new_left.statuses)==keys(new_right.statuses) || return false
    keys(new_left.references)==keys(new_right.references) || return false
    new_left.alias_signature==new_right.alias_signature || return false
    for field in (:statuses,:references)
        a,b,c,d=(getproperty(snapshot,field) for snapshot in (old_left,old_right,new_left,new_right))
        for key in intersect(keys(a),keys(c))
            (a[key]===c[key])==(b[key]===d[key]) || return false
        end
        for key in keys(c)
            typeof(c[key])===typeof(d[key]) || return false
            c[key]!==d[key] || return false
        end
    end
    return true
end

function work(simulation,fixture,config)
    state=Adapter.native_state(fixture.model,fixture.plant.id)
    scene=_scene_object(fixture.model).status
    leaves=PSE.model_objects(fixture.model;scale=:Leaf)
    records=scene.radiation_records
    positive=count(record->record.area_m2>0,records)
    nonzero=count(object->hasproperty(object.status,:A) &&
        hasproperty(object.status,:area_m2) && object.status.area_m2>0 &&
        !iszero(object.status.A),leaves)
    return (steps=PSE.current_step(simulation),objects=length(PSE.object_ids(fixture.model)),
        added_ids=sort!([repr(id.value) for id in setdiff(Set(PSE.object_ids(fixture.model)),Set(fixture.initial_ids))]),
        native_organ_slots=length(state.native.plant.organs),
        active_native_organs=count(organ->organ.active,state.native.plant.organs),
        native_processed_events=state.native.plant.processed,
        native_rng_draws=state.native.plant.rng.draws,
        projected_leaves=length(leaves),light_epochs=scene.light_epoch,
        opening_radiative_leaves=length(records),positive_area_lit_leaves=positive,
        nonzero_assimilation_rows=nonzero,
        actual_PB_kernel_call_count=nothing,
        kernel_count_scope=:uncollected_do_not_infer_from_target_counts)
end

"""Outside-clock nested durations, with explicit last-step/full-retention scope."""
function nested_clocks(simulation,fixture,config)
    scene=_scene_object(fixture.model)
    history=Dict{Symbol,Any}()
    for ((application,id,variable),stream) in PSE.outputs(simulation)
        application===:native_radiation && id==scene.id && _is_clock(application,variable) || continue
        history[variable]=[(time=first(sample),seconds=last(sample)) for sample in stream]
    end
    return (last_completed_step=(geometry_seconds=scene.status.geometry_seconds,
            light_seconds=scene.status.light_seconds),retained_clock_history=history,
        interpretation=:nested_wall_clocks_not_exclusive_phase_cost_or_PSE_overhead)
end

function check(simulation,fixture,config;require_positive=false)
    state=Adapter.native_state(fixture.model,fixture.plant.id)
    status=PSE.model_status(fixture.model,fixture.plant.id)
    scene=_scene_object(fixture.model).status
    observed=work(simulation,fixture,config)
    @testset "Original coupled physiology completed committed scientific work" begin
        @test PSE.current_step(simulation)<=config.steps
        @test scene.light_epoch==PSE.current_step(simulation)
        @test !state.coupled_pending
        @test state.growth_runtime[]===nothing
        @test !state.organ_growth.failed
        @test state.organ_growth.committed_revision==state.organ_growth.revision
        @test state.development.plant_identity==objectid(state.native.plant)
        @test state.organ_growth.owned_plant===nothing || state.organ_growth.owned_plant===state.native.plant
        @test isapprox(fixture.initial_reserve_gC+status.credited_carbon_supply_gC,
            status.remaining_carbon_gC+status.spent_carbon_gC+status.paid_carbon_loss_gC)
        @test all(record->record.area_m2>0 && record.aPPFD>=0,scene.radiation_records)
        @test all(record->record.physical_time>=0 && record.development_time>=0,scene.opening_plant_times)
        if PSE.current_step(simulation)>0
            @test state.development.physical_time>0
            @test scene.preceding_interval_seconds>0
        end
        if require_positive
            @test observed.positive_area_lit_leaves>0
            @test observed.nonzero_assimilation_rows>0
            @test fixture.radiation.last_scene!==nothing
            @test fixture.radiation.simulation!==nothing
        end
    end
    return (;passed=true,observed,require_positive,
        exclusions=EXCLUDED_CLOCK_OUTPUTS,scientific_validation=:bounded_integration_not_calibration)
end

"""All non-src scientific inputs needed to freeze the original coupled example."""
function source_paths()
    paths=String[ORIGINAL_BENCHMARK,
        joinpath(AMAP_ROOT,"examples","ecophysiology","native_growth.jl"),
        joinpath(AMAP_ROOT,"test","fixtures","native_originals","mod_Rauh.fpa"),
        joinpath(AMAP_ROOT,"test","fixtures","native_originals","merisier.fpa")]
    for (directory,_,files) in walkdir(joinpath(AMAP_ROOT,"dev","native")),file in files
        endswith(file,".jl") && push!(paths,joinpath(directory,file))
    end
    return sort!(unique!(paths))
end
source_manifest()=[(path=path,sha256=bytes2hex(sha256(read(path)))) for path in source_paths()]

end # module
