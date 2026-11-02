module DownstreamAMAPSimChecks
using Test
import PlantSimEngine as PSE
include("app/src/object_program.jl")
const BASELINE_ROOT=get(ENV,"PSE_AMAPSIM_PATH","/private/tmp/pse-juliac-large-20261102/sources/AMAPSim")
const TYPED_ROOT=get(ENV,"PSE_AMAPSIM_TYPED_PATH","/private/tmp/pse-juliac-large-20261102/typed-sources/AMAPSim")
ENV["PSE_AMAPSIM_PATH"]=BASELINE_ROOT
ENV["PSE_AMAPSIM_ADAPTER_PATH"]=BASELINE_ROOT
ENV["PSE_AMAPSIM_ADAPTER_VARIANT"]="original"
module Original
include("downstream_amapsim_fixture.jl")
end
ENV["PSE_AMAPSIM_ADAPTER_PATH"]=TYPED_ROOT
ENV["PSE_AMAPSIM_ADAPTER_VARIANT"]="typed"
module Typed
const ObjectPrograms=parentmodule(@__MODULE__).ObjectPrograms
include("downstream_amapsim_fixture.jl")
Base.include(DownstreamAMAPSimFixture,joinpath(@__DIR__,"downstream_amapsim_bridge.jl"))
end
const OF=Original.DownstreamAMAPSimFixture
const TF=Typed.DownstreamAMAPSimFixture
const OP=ObjectPrograms

function check_case(;nplants=1,steps=2,outputs=:all,increment=.5,seed=1,input=nothing)
    forcing=isnothing(input) ? NamedTuple() : (;input)
    oc=OF.config(;nplants,steps,outputs,increment,seed,forcing...)
    tc=TF.config(;nplants,steps,outputs,increment,seed,forcing...)
    original=OF.construct(oc);typed=TF.construct(tc);authored=TF.construct(tc)
    OF.admission(original);TF.admission(typed);TF.admission(authored)
    os=OF.prepare_baseline(original,oc);ts=TF.prepare_baseline(typed,tc)
    programme=OP.prepare(authored.model;constants=authored.constants)
    native=OP.instantiate(programme;retain=outputs===:all)
    native_fixture=(model=native,plant_ids=authored.plant_ids,initial_ids=authored.initial_ids)
    @test OF.fingerprint(os,original)==TF.fingerprint(ts,typed)
    @test TF.fingerprint(ts,typed)==TF.fingerprint(native,native_fixture)
    work=NamedTuple[]
    for step in 1:steps
        PSE.step!(os);PSE.step!(ts);OP.step!(native)
        @test OF.fingerprint(os,original)==TF.fingerprint(ts,typed)
        @test TF.fingerprint(ts,typed)==TF.fingerprint(native,native_fixture)
        push!(work,TF.work(native,native_fixture))
    end
    # Reusing the prepared programme must not reuse arenas, RNG or canonical refs.
    other=OP.instantiate(programme;retain=outputs===:all)
    @test PSE.current_step(other)==0
    @test isempty(other.organ_ids)
    @test other.plant_statuses[1]._native_pse_state.native.plant.rng !== native.plant_statuses[1]._native_pse_state.native.plant.rng
    before=TF.Bench.fingerprint(native.plant_statuses[1]._native_pse_state.native)
    OP.step!(other)
    @test TF.Bench.fingerprint(native.plant_statuses[1]._native_pse_state.native)==before
    OF.verify_sources(oc);TF.verify_sources(tc)
    return (plants=nplants,steps,outputs,work=last(work),lifetime_counter_entries=native.qualification_entries,
        registrations=native.registered_count,removals=native.removed_count,geometry_updates=native.geometry_updates)
end

function _call_outcome(f)
    try
        return (kind=:value,digest=TF._digest(f()))
    catch error
        return (kind=:error,type=typeof(error))
    end
end
"""Seeded forwarding matrix, including invalid optional combinations. Each
wrapper and its original sampler receive fresh independent identical RNG state.
"""
function check_optional_samplers()
    cfg=TF.config(input=joinpath(TF.ROOT,"test","fixtures","native_originals","merisier.fpa"))
    fixture=TF.construct(cfg)
    native=TF.Adapter.native_state(fixture.model,first(fixture.plant_ids)).native
    lp=first(native.plant.parameters.lateral_productions);zone=first(lp.zones)
    Engine=TF.Native.NativeAMAPPlantEngine;RNG=TF.Native.NativeAMAPLegacyRNG
    prepared=Engine.prepare_apical!(deepcopy(native.plant),first(native.plant.events))
    plan=prepared.plan
    @test_throws ArgumentError merge(plan,(unknown_native_plan_field=1,))
    updated=merge(plan,(next_time=1.0,))
    @test updated.next_time==1.0
    @test updated.immediate_branches===plan.immediate_branches
    @test updated.floating_cleanup_lateral_indices===plan.floating_cleanup_lateral_indices
    draws=0;cases=0
    for old in (nothing,false,true), previous_zone in (0,1), previous_pos in (NaN,1.0)
        left=RNG.ObservedRNG(7);right=RNG.ObservedRNG(7)
        branch=previous_zone==0 ? nothing : lp.zones[previous_zone].branching
        position=isnan(previous_pos) ? nothing : previous_pos
        expected=_call_outcome(()->TF.AMAPSim.sample_immediate_markov_state(left,zone,1.0,1,old;
            previous_branching=branch,previous_position=position))
        actual=_call_outcome(()->Engine._closed_sample_immediate_markov_state(right,zone,1.0,1,old,lp,previous_zone,previous_pos))
        @test actual==expected
        @test TF._digest(left)==TF._digest(right)
        draws+=right.draws;cases+=1
    end
    for old in (nothing,false,true), probability in (nothing,.25,.75), kind in (:cycle,:traumatic)
        left=RNG.ObservedRNG(7);right=RNG.ObservedRNG(7)
        if kind===:cycle
            expected=_call_outcome(()->TF.AMAPSim.sample_cycle_delayed_markov_state(left,zone,1.0,1,old;previous_initial_probability=probability))
            actual=_call_outcome(()->Engine._closed_sample_cycle_delayed_markov_state(right,zone,1.0,1,old,probability))
        else
            expected=_call_outcome(()->TF.AMAPSim.sample_traumatic_markov_state(left,zone,1.0,1,old;previous_initial_probability=probability))
            actual=_call_outcome(()->Engine._closed_sample_traumatic_markov_state(right,zone,1.0,1,old,probability))
        end
        @test actual==expected
        @test TF._digest(left)==TF._digest(right)
        draws+=right.draws;cases+=1
    end
    TF.verify_sources(cfg)
    return (cases,draws)
end
function run_checks(;steps=16)
    cases=NamedTuple[]
    samplers=Ref((cases=0,draws=0))
    result=@testset "Original AMAP architecture/geometry registry parity" begin
        for nplants in (1,4), outputs in (:all,:none)
            push!(cases,check_case(;nplants,steps,outputs))
        end
        rngcase=check_case(nplants=1,steps=8,outputs=:all,
            input=joinpath(OF.ROOT,"test","fixtures","native_originals","merisier.fpa"))
        @test sum(state.rng_draws for state in rngcase.work.native)>0
        push!(cases,rngcase)
        samplers[]=check_optional_samplers()
    end
    return (passes=result.n_passed,failures=length(result.results),cases=cases,samplers=samplers[])
end
end
