module MAESPAQualification

using Dates, Random, SHA, Serialization, Test, MAESPA, PlantSimEngine
const PSE=PlantSimEngine
const MAESPA_ROOT=realpath(pkgdir(MAESPA))
const EXPECTED_ROOT=realpath(get(ENV,"PSE_MAESPA_PATH",MAESPA_ROOT))
MAESPA_ROOT==EXPECTED_ROOT || error("Loaded MAESPA differs from PSE_MAESPA_PATH")
const EXAMPLE=joinpath(MAESPA_ROOT,"examples","two_species.jl")

# Include the unchanged package-owned example in a private namespace. No
# scenario is constructed and no scientific timestep runs during inclusion.
module Example
using MAESPA, PlantSimEngine
include(joinpath(pkgdir(MAESPA),"examples","two_species.jl"))
end

export config, construct, fingerprint, work, packages, source_snapshot,
    verify_source_snapshot, identities, same_identity_transitions,
    scientific_witness, check, check_profiled_work

function config(;steps::Integer=2,outputs=:all,T::Type{<:AbstractFloat}=Float64,
    start_slot::Integer=13,type_promotion=nothing)
    1<=start_slot<=48 || throw(ArgumentError("Start slot must be in the first day, 1:48"))
    1<=steps<=97-start_slot || throw(ArgumentError("Step budget exceeds remaining original two-day forcing"))
    outputs in (:none,:all) || throw(ArgumentError("Qualification supports outputs=:none/:all"))
    T in (Float32,Float64) || throw(ArgumentError("Small MAESPA qualification covers Float32/Float64"))
    promoted=type_promotion===nothing ? :none :
        type_promotion==Dict(Float64=>Float32) ? :Float64_to_Float32 :
        throw(ArgumentError("Qualification promotion must be nothing or Dict(Float64=>Float32)"))
    return (;kind=:maespa,steps=Int(steps),outputs,start_slot=Int(start_slot),
        parameter_type=Symbol(string(T)),status_promotion=promoted,
        trees=2,logical_leaf_units=16,forcing_steps=96,
        fixture=:unchanged_two_species_parameters_and_public_builder,
        scenario_scope=:native_canopy_soil_non_Tuzet_no_understorey_no_PB_extension)
end
_numeric_type(config)=config.parameter_type===:Float32 ? Float32 : Float64
_promotion(config)=config.status_promotion===:none ? nothing : Dict(Float64=>Float32)

function construct(configuration)
    input=Example.two_species_parameters(_numeric_type(configuration))
    model=MAESPA.build_model(input.config,input.scene;
        species_set=input.species,meteorology=input.meteorology,soil=input.soil,
        mount_leaf_exchange=true,type_promotion=_promotion(configuration),
        step_index=configuration.start_slot)
    return (;model,initial_ids=collect(PSE.object_ids(model)),
        constants=PSE.PlantMeteo.Constants(),package=:maespa)
end
packages()=(PSE,MAESPA)

# All numbers are represented with their exact Julia type and repr, including
# NaNs/Inf and Float32 values. Shapes/element types and every retained sample
# survive JSON serialization; snapshots do not depend on object addresses.
_canonical(x::Union{Nothing,Missing,Symbol,AbstractString})=x
_canonical(x::Union{Dates.TimeType,Dates.Period})=(type=string(typeof(x)),value=repr(x))
_canonical(x::Number)=(type=string(typeof(x)),value=repr(x))
_canonical(x::Type)=(type=:Julia_type,value=string(x))
_canonical(x::NamedTuple)=NamedTuple{keys(x)}(map(_canonical,values(x)))
_canonical(x::Tuple)=map(_canonical,x)
_canonical(x::Pair)=(_canonical(first(x)),_canonical(last(x)))
_canonical(x::AbstractArray)=(type=string(typeof(x)),element_type=string(eltype(x)),
    shape=size(x),values=[_canonical(value) for value in vec(x)])
_canonical(x::AbstractDict)=[(key=_canonical(k),value=_canonical(v))
    for (k,v) in sort!(collect(pairs(x));by=pair->repr(first(pair)))]
function _canonical(x)
    names=fieldnames(typeof(x))
    return (type=string(typeof(x)),fields=NamedTuple{names}(
        Tuple(_canonical(getfield(x,name)) for name in names)))
end
function _rngs!(rows,seen,value,path)
    value isa Union{Nothing,Missing,Number,AbstractString,Symbol,Type,Module,Function} && return nothing
    if ismutabletype(typeof(value))
        haskey(seen,value) && return nothing
        seen[value]=nothing
    end
    if value isa Random.AbstractRNG
        buffer=IOBuffer();serialize(buffer,copy(value))
        push!(rows,(;path,type=string(typeof(value)),
            state_sha256=bytes2hex(sha256(take!(buffer))),
            next_draws=repr(rand(copy(value),UInt64,4))))
    elseif value isa AbstractArray
        isbitstype(eltype(value)) && return nothing
        for (index,item) in enumerate(value)
            _rngs!(rows,seen,item,"$path[$index]")
        end
    elseif value isa AbstractDict
        for (key,item) in sort!(collect(pairs(value));by=pair->repr(first(pair)))
            _rngs!(rows,seen,item,"$path[$(repr(key))]")
        end
    else
        for name in fieldnames(typeof(value))
            isdefined(value,name) || continue
            _rngs!(rows,seen,getfield(value,name),"$path.$name")
        end
    end
    return nothing
end
function _scientific_rngs(model)
    rows=Any[];seen=IdDict{Any,Nothing}()
    for (index,spec) in pairs(model.applications)
        _rngs!(rows,seen,spec.model,"application[$index].$(spec.name)")
    end
    return rows
end
function fingerprint(simulation,fixture,configuration)
    objects=sort!(collect(PSE.model_objects(simulation.model));by=o->repr(o.id.value))
    states=[(id=_canonical(object.id.value),
        status_type=string(typeof(object.status)),
        fields=_canonical(PSE.final_state(simulation,object.id))) for object in objects]
    topology=[(id=_canonical(o.id.value),parent=_canonical(o.parent),
        children=_canonical(o.children),scale=o.scale,kind=o.kind,species=o.species,
        geometry=_canonical(PSE.geometry(o))) for o in objects]
    history=sort!([(key=repr(key),samples=[
        (time=_canonical(first(sample)),value=_canonical(last(sample))) for sample in stream])
        for (key,stream) in pairs(PSE.outputs(simulation))];by=row->row.key)
    return (;scientific=(step=PSE.current_step(simulation),states,history),topology,
        scientific_rngs=_scientific_rngs(simulation.model))
end

function identities(model)
    statuses=Dict{Any,Any}();references=Dict{Any,Any}()
    for object in PSE.model_objects(model)
        statuses[object.id]=object.status
        for name in propertynames(object.status)
            references[(object.id,name)]=PSE.refvalue(object.status,name)
        end
    end
    return (;statuses,references)
end
function same_identity_transitions(old_left,old_right,new_left,new_right)
    keys(new_left.statuses)==keys(new_right.statuses) || return false
    keys(new_left.references)==keys(new_right.references) || return false
    for name in (:statuses,:references)
        a,b,c,d=getproperty(old_left,name),getproperty(old_right,name),
            getproperty(new_left,name),getproperty(new_right,name)
        for key in intersect(keys(a),keys(c))
            typeof(c[key])===typeof(d[key]) || return false
            (a[key]===c[key])===(b[key]===d[key]) || return false
        end
    end
    return true
end
function scientific_witness(simulation)
    crowns=Any[]
    for object in PSE.model_objects(simulation.model)
        object.scale===:Crown || continue
        status=PSE.final_state(simulation,object.id)
        push!(crowns,(id=object.id.value,
            aggregation_available=status.crown_leaf_exchange_aggregation_available,
            daylight=status.leaf_exchange_daylight,
            daylight_available=status.leaf_exchange_daylight_available,
            controller_available=status.non_tuzet_crown_leaf_exchange_controller_available,
            accepted_leaf_slots=count(identity,status.non_tuzet_logical_leaf_exchange_available),
            accepted_leaf_trials=sum(status.non_tuzet_logical_leaf_temperature_trial_count),
            net_assimilation=repr(status.net_assimilation_crown_umol_co2_s),
            mean_leaf_temperature=repr(status.mean_leaf_temperature_crown_c)))
    end
    return sort!(crowns;by=row->repr(row.id))
end
function work(simulation,fixture,configuration)
    objects=collect(PSE.model_objects(simulation.model))
    scales=Dict{Symbol,Int}()
    for object in objects
        scale=object.scale===nothing ? :none : object.scale
        scales[scale]=get(scales,scale,0)+1
    end
    final_ids=Set(object.id for object in objects)
    witness=scientific_witness(simulation)
    counters=PSE.runtime_performance(simulation)
    return (steps=PSE.current_step(simulation),objects=length(objects),
        applications=length(simulation.compiled.applications),objects_by_scale=scales,
        added_ids=sort!([id.value for id in setdiff(final_ids,Set(fixture.initial_ids))];by=repr),
        streams=length(PSE.outputs(simulation)),
        retained_samples=sum(length(stream) for stream in values(PSE.outputs(simulation));init=0),
        ordinary_executor_verified=all(batch->batch isa PSE.CompiledExecutionBatch,
            simulation.execution_plan.batches),
        accepted_leaf_slots=sum(row.accepted_leaf_slots for row in witness;init=0),
        accepted_leaf_trials=sum(row.accepted_leaf_trials for row in witness;init=0),
        daylight_crowns=count(row->row.daylight,witness),
        profiled_root_target_entries=counters===nothing ? nothing : get(counters.counts,:execution_targets_visited,0),
        profiled_steps=counters===nothing ? nothing : get(counters.counts,:steps_executed,0))
end

_sha_file(path)=bytes2hex(sha256(read(path)))
function _git(command)
    try
        return readchomp(command)
    catch
        return nothing
    end
end
function source_snapshot()
    paths=String[EXAMPLE,joinpath(MAESPA_ROOT,"Project.toml")]
    for name in ("Manifest.toml",)
        path=joinpath(MAESPA_ROOT,name);isfile(path) && push!(paths,path)
    end
    for directory in ("src","ext")
        root=joinpath(MAESPA_ROOT,directory);isdir(root) || continue
        for (parent,_,files) in walkdir(root),file in files
            endswith(file,".jl") && push!(paths,joinpath(parent,file))
        end
    end
    sort!(unique!(paths))
    any(islink,paths) && error("MAESPA source snapshot refuses symlinked files")
    files=[(path=relpath(path,MAESPA_ROOT),sha256=_sha_file(path)) for path in paths]
    status=_git(`git -C $MAESPA_ROOT status --porcelain=v1`)
    diff=try read(`git -C $MAESPA_ROOT diff --binary HEAD`,String) catch; nothing end
    return (;root=MAESPA_ROOT,path=Base.pathof(MAESPA),version=string(Base.pkgversion(MAESPA)),
        revision=_git(`git -C $MAESPA_ROOT rev-parse HEAD`),
        git_status=status,git_diff_sha256=diff===nothing ? nothing : bytes2hex(sha256(diff)),
        files,aggregate_sha256=bytes2hex(sha256(join((row.path*"\0"*row.sha256 for row in files),"\n"))))
end
function verify_source_snapshot(expected)
    actual=source_snapshot()
    isequal(actual,expected) || error("MAESPA source/dirty-worktree image changed")
    return actual
end

function _same_shapes(left,right)
    keys(left.statuses)==keys(right.statuses) && keys(left.references)==keys(right.references) || return false
    return all(key->typeof(left.statuses[key])===typeof(right.statuses[key]),keys(left.statuses)) &&
        all(key->typeof(left.references[key])===typeof(right.references[key]),keys(left.references))
end
function _prepare(callback,fixture,arm,configuration;performance=false)
    return Base.invokelatest(callback,fixture.model,arm,configuration;
        constants=fixture.constants,performance)
end
function _check_science(simulation,fixture,configuration)
    actual=work(simulation,fixture,configuration)
    @test actual.steps==configuration.steps
    @test actual.objects_by_scale[:LogicalLeafUnit]==configuration.logical_leaf_units
    @test actual.objects_by_scale[:Crown]==configuration.trees
    @test isempty(actual.added_ids)
    @test actual.ordinary_executor_verified
    @test actual.accepted_leaf_slots==configuration.logical_leaf_units
    @test actual.accepted_leaf_trials>=configuration.logical_leaf_units
    for object in PSE.model_objects(simulation.model)
        object.scale===:Crown || continue
        status=PSE.final_state(simulation,object.id)
        @test status.crown_leaf_exchange_aggregation_available
        @test status.non_tuzet_crown_leaf_exchange_controller_available
        @test isfinite(status.net_assimilation_crown_umol_co2_s)
        @test isfinite(status.mean_leaf_temperature_crown_c)
    end
    if configuration.start_slot==13 && configuration.steps<=2
        @test actual.daylight_crowns==2
    end
    soil=PSE.final_state(simulation,:soil)
    @test soil.soil_water_balance_available
    @test abs(soil.soil_water_mass_balance_residual_m)<1e-7
    return actual
end

"""Untimed exact per-step none/all state, history, RNG, type and carrier checks.

`prepare(model,arm,config;constants,performance)` belongs to the common root
harness. No optimization trait or scientific method is installed here.
"""
function check(;prepare,steps=2,outputs_modes=(:none,:all),
    arms=(:ordinary_b,:graph_only,:prep_candidate),T=Float64,start_slot=13,
    type_promotion=nothing)
    before=source_snapshot();evidence=Any[]
    @testset "Original MAESPA preparation qualification" begin
        for outputs in outputs_modes
            configuration=config(;steps,outputs,T,start_slot,type_promotion)
            uninterrupted_fixture=construct(configuration)
            uninterrupted=_prepare(prepare,uninterrupted_fixture,:ordinary_a,configuration)
            PSE.continue!(uninterrupted;steps)
            uninterrupted_snapshot=fingerprint(uninterrupted,uninterrupted_fixture,configuration)
            for arm in arms
                a,b=construct(configuration),construct(configuration)
                left=_prepare(prepare,a,:ordinary_a,configuration)
                right=_prepare(prepare,b,arm,configuration)
                old_left,old_right=identities(left.model),identities(right.model)
                @test _same_shapes(old_left,old_right)
                @test all(key->old_left.references[key]!==old_right.references[key],keys(old_left.references))
                @test isequal(fingerprint(left,a,configuration),fingerprint(right,b,configuration))
                for tick in 1:steps
                    tick==1 ? PSE.step!(left) : PSE.continue!(left;steps=1)
                    tick==1 ? PSE.step!(right) : PSE.continue!(right;steps=1)
                    @test isequal(fingerprint(left,a,configuration),fingerprint(right,b,configuration))
                    new_left,new_right=identities(left.model),identities(right.model)
                    @test _same_shapes(new_left,new_right)
                    @test same_identity_transitions(old_left,old_right,new_left,new_right)
                    old_left,old_right=new_left,new_right
                end
                @test isequal(fingerprint(right,b,configuration),uninterrupted_snapshot)
                actual=_check_science(right,b,configuration)
                @test actual==work(left,a,configuration)
                push!(evidence,(;arm,outputs,configuration,work=actual,
                    scientific_witness=scientific_witness(right),
                    exact_state_history_rng_types_reference_transitions_and_continuation=true))
            end
        end
        @test isequal(verify_source_snapshot(before),before)
    end
    return (;passed=true,kind=:maespa,evidence,source=before,benchmark_claim=false,
        executor=:ordinary_PSE_executor_with_original_MAESPA_kernels,
        qualification=:small_frozen_original_example_case_not_full_MAESPA_feature_matrix)
end

"""Separate instrumentation gate; its time is never a performance sample."""
function check_profiled_work(;prepare,steps=1,arms=(:ordinary_a,:graph_only,:prep_candidate),start_slot=13)
    configuration=config(;steps,outputs=:all,start_slot);evidence=Any[]
    @testset "MAESPA actual root execution and accepted scientific work" begin
        for arm in arms
            fixture=construct(configuration)
            simulation=_prepare(prepare,fixture,arm,configuration;performance=true)
            PSE.continue!(simulation;steps)
            actual=_check_science(simulation,fixture,configuration)
            @test actual.profiled_steps==steps
            @test actual.profiled_root_target_entries>0
            push!(evidence,(;arm,work=actual,counts=PSE.runtime_performance(simulation).counts))
        end
    end
    return (;passed=true,evidence,timing_qualified=false,
        counter_scope=:actual_scheduler_root_entries_not_inferred_nested_kernel_counts)
end

end # module
