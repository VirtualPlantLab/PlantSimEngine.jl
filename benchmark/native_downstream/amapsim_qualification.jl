module AMAPQualification

using AMAPSim, PlantSimEngine, SHA, Test
const PSE=PlantSimEngine
const ROOT=realpath(pkgdir(AMAPSim))
const EXPECTED_ROOT=realpath(get(ENV,"PSE_AMAPSIM_PATH",ROOT))
ROOT==EXPECTED_ROOT || error("AMAPQualification loaded AMAPSim from an unexpected package root")
const BENCHMARK_SOURCE=joinpath(ROOT,"benchmark","native_pse_benchmark.jl")
isfile(BENCHMARK_SOURCE) || error("The frozen AMAP package requires benchmark/native_pse_benchmark.jl")

# Definitions only. Reuse the original native scientific engine, PSE adapter,
# length consumer and complete native arena/RNG fingerprint without patching any
# package method. This include executes no scientific trajectory or benchmark.
include(BENCHMARK_SOURCE)
const Bench=NativePSEBenchmark
const Native=Bench.N
const Adapter=Bench.B

export config,construct,fingerprint,work,packages,check,identities,
    same_identity_transitions,source_image,verify_sources,assert_projection

const ARMS=(:ordinary_a,:ordinary_b,:graph_only,:prep_candidate)
const PRIVATE_STATE=:_native_pse_state

# A deliberately small qualification-only consumer. It changes no native model
# and is identical in all arms. Its dependency runs after the original
# LengthProbe, while the integer output proves actual per-organ/newborn entries
# even when no output history is retained.
PSE.@process "amap_qualification_count" verbose=false
struct QualificationCount <: AbstractAmap_Qualification_CountModel end
PSE.inputs_(::QualificationCount)=(observed_length=PSE.Required(Real),)
PSE.outputs_(::QualificationCount)=(qualification_runs=0,)
function PSE.run!(::QualificationCount,status,environment,constants,context)
    status.qualification_runs+=1
    return nothing
end

"""Tiny original AMAP architecture case with real PSE internode consumers.

The initial native/PSE organ population is empty. The deterministic branch46
input produces actual organs by development time 0.5 in the upstream tests.
FPA parsing is charged to construction in this adapter. All variants use the
same outer native increment and recompute geometry at every coupling boundary.
"""
function config(;steps::Integer=2,increment::Real=0.5,seed::Integer=1,
    outputs=:none,nplants::Integer=1,
    input=joinpath(ROOT,"test","fixtures","native_arena","branch46.fpa"))
    steps>0 || throw(ArgumentError("AMAP qualification requires positive steps"))
    isfinite(increment) && increment>0 || throw(ArgumentError("Positive finite increment required"))
    nplants>0 || throw(ArgumentError("Positive plant count required"))
    0<=seed<=typemax(UInt64)-(nplants-1) || throw(ArgumentError("Seed range must fit UInt64"))
    input=realpath(input)
    return (;kind=:amapsim,steps=Int(steps),increment=Float64(increment),seed=UInt64(seed),
        outputs,nplants=Int(nplants),input,input_sha256=bytes2hex(sha256(read(input))),
        geometry=true,requested_scale=:IN,initial_native_organs=0,
        construction_includes_FPA_parsing=true,
        qualification_consumer=:harness_only_integer_count_after_original_LengthProbe,
        source_root=ROOT,benchmark_source_sha256=bytes2hex(sha256(read(BENCHMARK_SOURCE))))
end

"""Build fresh arenas, geometry state, registry, statuses and scientific RNGs."""
function construct(cfg)
    parameters=AMAPSim.read_parameters(cfg.input)
    plant_ids=cfg.nplants==1 ? (:plant,) : Tuple(Symbol("plant_",i) for i in 1:cfg.nplants)
    plants=Tuple(Adapter.NativePlant(id,parameters;
        seed=cfg.seed+UInt64(i-1),development_increment=cfg.increment)
        for (i,id) in pairs(plant_ids))
    applications=(
        PSE.ModelSpec(Bench.LengthProbe();name=:length_probe,on=PSE.Many(scale=:IN)),
        PSE.ModelSpec(QualificationCount();name=:qualification_count,on=PSE.Many(scale=:IN),
            inputs=(observed_length=PSE.One(within=PSE.Self(),
                application=:length_probe,var=:observed_length),)),
    )
    model=Adapter.scenario(plants;applications,scales=(Internode=:IN,),geometry=cfg.geometry)
    return (;model,initial_ids=collect(PSE.object_ids(model)),plant_ids,
        constants=PSE.PlantMeteo.Constants(),package=:amapsim)
end
packages()=(PSE,AMAPSim)
_native(fixture,id)=Adapter.native_state(fixture.model,id).native
_digest(value)=begin
    io=IOBuffer();Bench.value_bytes!(io,value);bytes2hex(sha256(take!(io)))
end

# Skip only the adapter's private live native-state pointer from the registry
# digest: every changing native arena, event, trace and RNG word is independently
# encoded by the original benchmark fingerprint. No timings are status outputs
# in this architecture-only fixture.
function _registry_state(fixture)
    objects=collect(PSE.model_objects(fixture.model))
    rows=sort!([(
        id=object.id.value,parent=object.parent===nothing ? nothing : object.parent.value,
        children=Tuple(id.value for id in object.children),name=object.name,
        kind=object.kind,scale=object.scale,species=object.species,
        geometry=PSE.geometry(object),
        fields=Tuple((name=name,type=string(typeof(getproperty(object.status,name))),
            value=getproperty(object.status,name))
            for name in propertynames(object.status) if name!==PRIVATE_STATE),
    ) for object in objects];by=row->repr(row.id))
    return (;iteration_ids=Tuple(object.id.value for object in objects),rows)
end
function _histories(simulation)
    return sort!([(
        key=repr(key),stream_type=string(typeof(stream)),
        samples=Tuple((time=first(sample),type=string(typeof(last(sample))),value=last(sample))
            for sample in stream),
    ) for (key,stream) in pairs(PSE.outputs(simulation))];by=row->row.key)
end
function fingerprint(simulation,fixture,cfg)
    native=Tuple(let state=Adapter.native_state(fixture.model,id)
        (id=id,digest=Bench.fingerprint(state.native),
            adapter_registered_sha256=_digest(state.registered),
            geometry=state.geometry,coupled_pending=state.coupled_pending,
            growth_runtime_active=state.growth_runtime[]!==nothing)
    end for id in fixture.plant_ids)
    return (;step=PSE.current_step(simulation),native,
        registry_sha256=_digest(_registry_state(fixture)),outputs_sha256=_digest(_histories(simulation)))
end

function work(simulation,fixture,cfg)
    objects=collect(PSE.model_objects(fixture.model))
    internodes=PSE.model_objects(fixture.model;scale=:IN)
    ids=Set(object.id for object in objects)
    consumer_bindings=[binding for binding in simulation.compiled.input_bindings
        if binding.application_id in (:length_probe,:qualification_count) && binding.consumer_id in ids]
    reference_bindings=count(PSE.Diagnostics.has_reference_carrier,consumer_bindings)
    native=Tuple((id=id,
        axes=count(axis->axis.active,_native(fixture,id).plant.axes),
        raw_organs=length(_native(fixture,id).plant.organs),
        active_organs=count(organ->organ.active && _native(fixture,id).plant.axes[organ.axis].active,
            _native(fixture,id).plant.organs),
        time=_native(fixture,id).plant.time,
    ) for id in fixture.plant_ids)
    return (;steps=PSE.current_step(simulation),objects=length(objects),internodes=length(internodes),
        added_ids=sort!([id.value for id in setdiff(ids,Set(fixture.initial_ids))];by=repr),
        qualification_invocations=sum(object.status.qualification_runs for object in internodes;init=0),
        active_consumer_bindings=length(consumer_bindings),reference_consumer_bindings=reference_bindings,
        retained_streams=length(PSE.outputs(simulation)),native,
        scientific_scope=:original_native_architecture_and_geometry_with_real_PSE_organ_projection,
        consumer_scope=:original_LengthProbe_plus_identical_harness_only_counter,
        native_only_role=:scientific_equivalence_negative_control_not_PSE_performance_candidate)
end

"""Validate real projected domains, original consumer results and live references."""
function assert_projection(simulation,fixture,cfg;require_work=true)
    expected=PSE.ObjectId[]
    for id in fixture.plant_ids
        state=Adapter.native_state(fixture.model,id)
        @test state.growth_runtime[]===nothing
        @test state.growth_control===nothing
        @test state.development===nothing
        @test state.organ_growth===nothing
        @test !state.coupled_pending
        native=state.native
        append!(expected,(Adapter.native_object_id(id,:Internode,index)
            for (index,organ) in pairs(native.plant.organs)
            if organ.active && native.plant.axes[organ.axis].active))
    end
    actual=collect(PSE.model_objects(fixture.model;scale=:IN))
    @test Set(object.id for object in actual)==Set(expected)
    require_work && (@test !isempty(actual))
    for object in actual
        plant,semantic,index=object.id.value
        @test semantic===:Internode
        organ=_native(fixture,plant).plant.organs[index]
        @test isequal(object.status.length,organ.length)
        @test isequal(object.status.observed_length,organ.length)
        @test object.status.qualification_runs>0
        @test !ismutable(object.geometry)
        for name in (:base,:tip,:frame,:length,:diameter_top,:diameter_bottom)
            @test isequal(getproperty(object.geometry,name),getproperty(organ,name))
        end
        for (application,input) in ((:length_probe,:length),(:qualification_count,:observed_length))
            binding=only(binding for binding in simulation.compiled.input_bindings
                if binding.application_id===application && binding.consumer_id==object.id && binding.input===input)
            @test PSE.Diagnostics.has_reference_carrier(binding)
            @test PSE.Diagnostics.input_carrier(binding)===PSE.refvalue(object.status,input)
        end
    end
    report=work(simulation,fixture,cfg)
    if require_work
        @test report.qualification_invocations>0
        @test report.active_consumer_bindings>=2*length(actual)
        @test report.reference_consumer_bindings==report.active_consumer_bindings
        @test !isempty(report.added_ids)
    end
    return report
end

function identities(fixture)
    statuses=Dict{Any,Any}();references=Dict{Any,Any}()
    for object in PSE.model_objects(fixture.model)
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
    for key in intersect(keys(old_left.statuses),keys(new_left.statuses))
        (old_left.statuses[key]===new_left.statuses[key])===
            (old_right.statuses[key]===new_right.statuses[key]) || return false
    end
    for key in intersect(keys(old_left.references),keys(new_left.references))
        (old_left.references[key]===new_left.references[key])===
            (old_right.references[key]===new_right.references[key]) || return false
    end
    return all(key->typeof(new_left.statuses[key])===typeof(new_right.statuses[key]),keys(new_left.statuses)) &&
        all(key->typeof(new_left.references[key])===typeof(new_right.references[key]),keys(new_left.references))
end

function _prepare(fixture,arm,cfg;performance=false)
    arm in ARMS || throw(ArgumentError("Unknown AMAP qualification arm"))
    if arm in (:graph_only,:prep_candidate)
        Main.GraphRowProjection.enable_graph_row_projection!(fixture.model)
    end
    arm===:prep_candidate && Main.TypedOutputPreparation.enable_typed_output_preparation!(fixture.model)
    return PSE.run!(fixture.model;steps=0,outputs=cfg.outputs,constants=fixture.constants,performance)
end

"""Small per-step gates; native-only is never used as a PSE speed comparison."""
function check(arm::Symbol=:prep_candidate;steps=2,continuation=1,increment=0.5,
    outputs_modes=(:none,:all),seed=1,nplants=1,input=joinpath(ROOT,"test","fixtures","native_arena","branch46.fpa"))
    results=Any[]
    @testset "Original AMAP growth and PSE projection preparation qualification" begin
        for outputs in outputs_modes
            cfg=config(;steps,increment,outputs,seed,nplants,input)
            before_sources=source_image(cfg)
            left,right=construct(cfg),construct(cfg)
            @test left.model!==right.model
            @test all(id->_native(left,id)!==_native(right,id),left.plant_ids)
            ordinary=_prepare(left,:ordinary_a,cfg)
            candidate=_prepare(right,arm,cfg)
            old_left,old_right=identities(left),identities(right)
            @test all(key->old_left.references[key]!==old_right.references[key],keys(old_left.references))
            @test isequal(fingerprint(ordinary,left,cfg),fingerprint(candidate,right,cfg))
            direct=Dict(id=>Native.NativeModel(cfg.input;seed=cfg.seed+UInt64(i-1))
                for (i,id) in pairs(left.plant_ids))
            first_seen=Dict{PSE.ObjectId,Int}();per_step=Any[]
            for tick in 1:(steps+continuation)
                if tick<=steps
                    PSE.step!(ordinary);PSE.step!(candidate)
                else
                    PSE.continue!(ordinary;steps=1);PSE.continue!(candidate;steps=1)
                end
                @test isequal(fingerprint(ordinary,left,cfg),fingerprint(candidate,right,cfg))
                for id in left.plant_ids
                    Native.advance_to!(direct[id],direct[id].plant.time+cfg.increment;geometry=cfg.geometry)
                    @test Bench.fingerprint(direct[id])==Bench.fingerprint(_native(left,id))
                    @test Bench.fingerprint(direct[id])==Bench.fingerprint(_native(right,id))
                end
                expected=assert_projection(ordinary,left,cfg)
                actual=assert_projection(candidate,right,cfg)
                @test isequal(actual,expected)
                for object in PSE.model_objects(right.model;scale=:IN)
                    born=get!(first_seen,object.id,tick)
                    @test object.status.qualification_runs==tick-born+1
                end
                next_left,next_right=identities(left),identities(right)
                @test same_identity_transitions(old_left,old_right,next_left,next_right)
                old_left,old_right=next_left,next_right
                @test all(batch->batch isa PSE.CompiledExecutionBatch,candidate.execution_plan.batches)
                push!(per_step,(;tick,work=actual))
            end
            @test source_image(cfg)==before_sources
            push!(results,(;outputs,per_step,final=fingerprint(candidate,right,cfg)))
        end
    end
    return (;passed=true,arm,steps,continuation,increment,results,
        scientific_code=:original_native_and_PSE_adapter_unmodified,
        preservation=:exact_native_arenas_geometry_RNG_registry_status_histories_and_live_reference_transitions)
end

"""Exact source/input inventory for external copying and before/after guards.

Only the requested FPA is needed by this standalone architecture fixture. The
root qualification controller additionally snapshots the coupled example and
its fixtures when composing a broader package cohort. Dirty source status is
recorded by that controller before the package is frozen; no downstream checkout
or git metadata is modified here.
"""
function source_image(cfg)
    files=String[]
    for component in ("src","ext",joinpath("dev","native"))
        directory=joinpath(ROOT,component)
        isdir(directory) || continue
        for (dir,_,names) in walkdir(directory),name in names
            endswith(name,".jl") && push!(files,joinpath(dir,name))
        end
    end
    for path in (BENCHMARK_SOURCE,joinpath(ROOT,"Project.toml"),joinpath(ROOT,"Manifest.toml"),cfg.input)
        isfile(path) && push!(files,path)
    end
    return [(path=relpath(path,ROOT),sha256=bytes2hex(sha256(read(path))))
        for path in sort!(unique!(files))]
end
verify_sources(cfg,image)=source_image(cfg)==image || error("Frozen AMAP source/input image changed")

end # module
