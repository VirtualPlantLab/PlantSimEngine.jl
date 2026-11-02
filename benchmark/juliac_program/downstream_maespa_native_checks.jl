isdefined(@__MODULE__,:DownstreamMAESPARegistry) || include(joinpath(@__DIR__,"downstream_maespa_registry.jl"))
isdefined(@__MODULE__,:DownstreamMAESPAChecks) || include(joinpath(@__DIR__,"downstream_maespa_checks.jl"))
isdefined(@__MODULE__,:DownstreamMAESPAProvenance) || include(joinpath(@__DIR__,"downstream_maespa_provenance.jl"))

module DownstreamMAESPANativeChecks
using Test
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPARegistry as Adapter
import ..DownstreamMAESPAChecks as Checks
import ..DownstreamMAESPAProvenance as Provenance
const Registry=Adapter.Registry

"""Temporal fallback narrowing preserves generic values and nested aliases."""
function check_temporal_initials()
    @testset "Closed temporal initial schemas" begin
        scalar=Ref(2.0f0)
        @test Registry._typed_temporal_initial(scalar,2.0f0,Val(false))===2.0f0
        carrier=Ref(Fixture.PSE.RefVector([Ref(1.0f0),Ref(2.0f0)]))
        narrowed=Registry._typed_temporal_initial(carrier,Any[1.0f0,2.0f0],Val(true))
        @test narrowed isa Vector{Float32}
        @test narrowed==Float32[1,2]
        payload=[3.0]
        vectors=Ref(Fixture.PSE.RefVector([Ref(payload),Ref(payload)]))
        aliases=Registry._typed_temporal_initial(vectors,Any[payload,payload],Val(true))
        @test aliases isa Vector{Vector{Float64}}
        @test aliases[1]===payload===aliases[2]
        @test_throws ArgumentError Registry._typed_temporal_initial(carrier,Any[1.0,2.0],Val(true))
        @test_throws DimensionMismatch Registry._typed_temporal_initial(carrier,Any[1.0f0],Val(true))
        empty_carrier=Ref(Fixture.PSE.RefVector{Float64}())
        @test Registry._typed_temporal_initial(empty_carrier,Any[],Val(true)) isa Vector{Float64}
    end
    return (closed_temporal_initial_checks=8,)
end

"""Dynamic call names resolve to the admitted typed route without copying views."""
function check_call_views(state)
    count=0
    @testset "Finite registry hard-call views" begin
        for group in state.groups,target in group.targets
            isempty(keys(target.calls)) && continue
            context=Registry.RegistryContext(state,target,Registry.NoOverride(),float(state.step),true)
            for name in keys(target.calls)
                route=getproperty(target.calls,name)
                targets=Fixture.PSE.call_targets(context,name)
                @test length(targets)==length(route.members)
                for index in eachindex(targets)
                    family,row=route.members[index]
                    expected=state.groups[family].targets[row]
                    @test targets[index].object_id==expected.object_id
                    @test targets[index].status===expected.status
                    count+=1
                end
                if length(targets)==1
                    family,row=only(route.members)
                    @test Fixture.PSE.call_model(context,name)===state.groups[family].targets[row].model
                end
            end
            @test_throws ArgumentError Fixture.PSE.call_targets(context,:undeclared_probe)
        end
    end
    return (checked_call_targets=count,)
end

"""Exact observations from an independent ordinary run and the safe executable.
The baseline uses the manifest-approved original or inference-typed source.
"""
function check_native(bundle;config=Fixture.configuration(),directory=mktempdir(),variant=:typed)
    config.T===Float64 || throw(ArgumentError("this native scenario suite was authored for Float64"))
    before=Fixture.source_snapshot()
    provenance=Provenance.verify_bundle(bundle,before;variant)
    Provenance.require_case(provenance,config)
    mkpath(directory)
    fixture=Fixture.construct(config)
    ordinary=Fixture.ordinary_start(fixture)
    trace=NamedTuple[]
    for _ in 1:config.steps
        Fixture.ordinary_advance!(ordinary)
        push!(trace,Fixture.work_witness(ordinary))
    end
    expected=joinpath(directory,"ordinary.txt")
    actual=joinpath(directory,"native.txt")
    open(io->Adapter.print_ordinary(ordinary,io),expected,"w")
    command=Cmd([provenance.launcher,"emit",string(config.steps),string(config.copies),
        string(config.start_slot),String(config.outputs)])
    run(pipeline(command;stdout=actual))
    expected_rows=sort!(readlines(expected)); actual_rows=sort!(readlines(actual))
    @testset "MAESPA native/ordinary full records, $(config.copies) tiles × $(config.steps) steps" begin
        @test !isempty(expected_rows)
        equal=isequal(actual_rows,expected_rows)
        @test equal
        for witness in trace
            Checks._check_witness(witness,config)
        end
        Checks._check_positive_work(trace)
        @test isequal(Fixture.source_snapshot(),before)
        Provenance.verify_unchanged(provenance,Fixture.source_snapshot();variant)
    end
    return (configuration=config,baseline=:ordinary_PSE,executor=:JuliaC_safe,
        record_count=length(expected_rows),exact_full_observation_parity=true,
        expected,actual,source_variant=variant,source_sha256=before.aggregate_sha256,build=provenance.metadata,trace)
end

"""Two private instances reuse one authored program without sharing live state."""
function check_reuse(;config=Fixture.configuration())
    fixture=Fixture.construct(config)
    program=Registry.prepare(fixture.model;outputs=config.outputs,constants=fixture.constants)
    left=Registry.instantiate(program); right=Registry.instantiate(program)
    untouched=Adapter.snapshot(right,fixture)
    @testset "MAESPA one-program private state ownership" begin
        @test left.environment!==right.environment
        @test left.environment.forcing_backend.source===getfield(left.environment.forcing,:ts)
        @test right.environment.forcing_backend.source===getfield(right.environment.forcing,:ts)
        @test left.environment.forcing_backend.source!==right.environment.forcing_backend.source
        @test all(target.environment.backend===left.environment for group in left.groups for target in group.targets)
        @test all(target.environment.backend===right.environment for group in right.groups for target in group.targets)
        Registry.step!(left)
        @test isequal(Adapter.snapshot(right,fixture),untouched)
        third=Registry.instantiate(program)
        @test isequal(Adapter.snapshot(third,fixture),untouched)
        Registry.advance!(right,config.steps)
        Registry.advance!(left,config.steps-1)
        @test isequal(Adapter.snapshot(left,fixture),Adapter.snapshot(right,fixture))
        @test isnothing(fixture.model.binding_cache)
    end
    return (configuration=config,independent_instances=true,families=length(program.seed.groups),
        application_count=length(program.seed.applications))
end

end
