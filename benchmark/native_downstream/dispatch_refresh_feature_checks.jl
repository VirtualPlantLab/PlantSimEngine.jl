module DispatchRefreshFeatureChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI
const C = Main.GrowthInputReuseChecks
const N = Main.NewbornPreparationChecks
const D = Main.NewbornDistributedChecks
const H = Main.XPDispatchRefreshMeasurements
export dispatch_refresh_feature_checks

function _enable!(model)
    Main.TypedOutputPreparation.enable_typed_output_preparation!(model)
    Main.TrustedExecutionGroupIndex.enable_trusted_execution_group_index!(model)
    return model
end

function _pair(left,right;outputs=:all)
    reference=PSE.run!(left;steps=0,outputs)
    _enable!(right)
    candidate=PSE.run!(right;steps=0,outputs)
    return reference,candidate,C._initial_pair(reference,candidate)
end
function _step_pair!(reference,candidate,previous)
    PSE.step!(reference);PSE.step!(candidate)
    next=C._pair_state(reference,candidate,previous)
    C._live_bindings(reference);C._live_bindings(candidate)
    return next
end
function _coverage(simulation)
    # Generic cases need not have an empty application slot. Record real
    # trusted hits without inventing absent-slot work for those cases.
    return H.dispatch_refresh_coverage(simulation,:trusted_barrier,:generic;
        require_growth=false)
end

# Small canonical spatial backend: the existing coalesced-growth environment
# test contract, reduced to one movement, one addition and one cached hard call.
mutable struct SpatialBackend <: EA.AbstractEnvironmentBackend
    samples::Vector{Tuple{PSE.ObjectId,Symbol,Float32}}
end
SpatialBackend()=SpatialBackend(Tuple{PSE.ObjectId,Symbol,Float32}[])
EA.base_step_seconds(::SpatialBackend)=3600.0
EA.get_nsteps(::SpatialBackend)=4
EA.environment_variables(::SpatialBackend)=Set((:T,))
EA.bind_environment(::SpatialBackend,object::PSE.Object,context,config)=
    (cell=PSE.geometry(object).cell,object_id=context.object_id)
function EA.sample(backend::SpatialBackend,handle,variable::Symbol,time)
    variable===:T || error("Unexpected environment variable")
    value=handle.cell===:sun ? 10.0f0 : 20.0f0
    push!(backend.samples,(handle.object_id,handle.cell,value))
    return value
end
PSE.@process "dispatch_feature_spatial" verbose=false
struct SpatialProbe <: AbstractDispatch_Feature_SpatialModel end
PSE.inputs_(::SpatialProbe)=NamedTuple()
PSE.outputs_(::SpatialProbe)=(seen=0.0f0,visits=0)
PSE.environment_inputs_(::SpatialProbe)=(T=0.0f0,)
function PSE.run!(::SpatialProbe,status,environment,constants,context)
    status.seen=environment.T;status.visits+=1
    return nothing
end
PSE.@process "dispatch_feature_owner" verbose=false
struct CallOwner <: AbstractDispatch_Feature_OwnerModel end
PSE.inputs_(::CallOwner)=NamedTuple()
PSE.outputs_(::CallOwner)=(observed=0.0f0,)
function PSE.run!(::CallOwner,status,environment,constants,context)
    target=only(PSE.run_call!(context,:probe;publish=true))
    status.observed=target.status.seen
    return nothing
end
function _spatial_fixture()
    backend=SpatialBackend()
    model=PSE.CompositeModel(
        PSE.Object(1;kind=:spatial_unit,geometry=(cell=:sun,)),
        PSE.Object(2;kind=:spatial_unit,geometry=(cell=:sun,)),
        PSE.Object(:owner;geometry=(cell=:sun,));
        applications=(PSE.ModelSpec(SpatialProbe();name=:probe,
            on=PSE.Many(kind=:spatial_unit),every=Hour(1)),
            PSE.ModelSpec(CallOwner();name=:owner,on=PSE.One(id=:owner),every=Hour(1),
                calls=(probe=PSE.One(id=1,within=PSE.SceneScope(),application=:probe),))),
        environment=backend)
    return (;model,backend)
end

PSE.@process "dispatch_feature_generic" verbose=false
struct GenericState{T} <: AbstractDispatch_Feature_GenericModel
    increment::T
end
PSE.inputs_(::GenericState)=NamedTuple()
PSE.outputs_(model::GenericState{T}) where {T}=
    (value=zero(model.increment),payload=T[1,2],visits=0)
function PSE.run!(model::GenericState,status,environment,constants,context)
    status.value+=model.increment;status.visits+=1
    return nothing
end
struct ConversionTrace
    calls::Vector{Tuple{Symbol,DataType}}
end
function (trace::ConversionTrace)(variable,value)
    push!(trace.calls,(variable,typeof(value)))
    return value
end
function _override_fixture(::Type{T};convert=false) where {T}
    trace=Tuple{Symbol,DataType}[]
    template=PSE.CompositeModelTemplate((PSE.ModelSpec(GenericState(T(2));name=:state,
        on=PSE.Many(kind=:generic_unit),every=Hour(1)),))
    instance=PSE.ObjectInstance(:plant,template;root=PSE.Object(:plant;kind=:plant,status=PSE.Status(root_marker=0)),
        objects=(PSE.Object(:a;kind=:generic_unit,parent=:plant),
            PSE.Object(:b;kind=:generic_unit,parent=:plant)),
        object_overrides=(PSE.Override(object=:b,application=:state,model=GenericState(T(7))),))
    model=PSE.CompositeModel(instance;environment=(duration=Hour(1),),
        type_promotion=convert ? Dict(Float64=>Float32) : nothing,
        status_transform=ConversionTrace(trace))
    return (;model,trace)
end

"""Tiny ordinary-versus-combined feature gates; no benchmarks or kernel wrapping.

Dependencies are the current dispatch measurement module and existing growth /
newborn fixture modules. Default suite uses five tiny independent scenario pairs.
"""
function dispatch_refresh_feature_checks(;cases=(:initializer_multirate,
    :distributed,:spatial_call_growth,:converted_override,:bigfloat_override),outputs=:all)
    evidence=Any[]
    @testset "Typed output and trusted index preserve composed PSE features" begin
        for case in cases
            if case===:initializer_multirate
                left=N.preparation_fixture(;source_every=Hour(2))
                right=N.preparation_fixture(;source_every=Hour(2))
                reference,candidate,previous=_pair(left.model,right.model;outputs)
                for step in 1:4
                    previous=_step_pair!(reference,candidate,previous)
                    @test isequal(N._snapshot(reference),N._snapshot(candidate))
                    @test PSE.model_status(candidate.model,0).second_sample===
                        PSE.model_status(candidate.model,0).first_sample+1.0f0
                end
            elseif case===:distributed
                reference,candidate,previous=_pair(D.distributed_fixture(:from_status),
                    D.distributed_fixture(:from_status);outputs)
                for _ in 1:3
                    previous=_step_pair!(reference,candidate,previous)
                    @test isequal(N._snapshot(reference),N._snapshot(candidate))
                end
            elseif case===:spatial_call_growth
                left,right=_spatial_fixture(),_spatial_fixture()
                reference,candidate,previous=_pair(left.model,right.model;outputs)
                previous=_step_pair!(reference,candidate,previous)
                stable=(PSE.refvalue(PSE.model_status(left.model,1),:seen),
                    PSE.refvalue(PSE.model_status(right.model,1),:seen))
                for simulation in (reference,candidate)
                    PSE.register_object!(simulation.model,PSE.Object(3;
                        kind=:spatial_unit,geometry=(cell=:sun,)))
                    PSE.move_object!(simulation.model,1,(cell=:shade,))
                end
                previous=_step_pair!(reference,candidate,previous)
                @test left.backend.samples==right.backend.samples
                @test PSE.model_status(right.model,:owner).observed===20.0f0
                @test PSE.refvalue(PSE.model_status(left.model,1),:seen)===stable[1]
                @test PSE.refvalue(PSE.model_status(right.model,1),:seen)===stable[2]
                for simulation in (reference,candidate)
                    PSE.move_object!(simulation.model,1,(cell=:sun,))
                end
                previous=_step_pair!(reference,candidate,previous)
                @test left.backend.samples==right.backend.samples
                @test PSE.model_status(right.model,:owner).observed===10.0f0
            elseif case in (:converted_override,:bigfloat_override)
                T=case===:converted_override ? Float64 : BigFloat
                convert=case===:converted_override
                left,right=_override_fixture(T;convert),_override_fixture(T;convert)
                reference,candidate,previous=_pair(left.model,right.model;outputs)
                @test left.trace==right.trace
                previous=_step_pair!(reference,candidate,previous)
                for simulation in (reference,candidate)
                    PSE.register_object!(simulation.model,PSE.Object(:c;
                        kind=:generic_unit,parent=:plant))
                end
                previous=_step_pair!(reference,candidate,previous)
                @test left.trace==right.trace
                expected_type=convert ? Float32 : BigFloat
                @test PSE.model_status(right.model,:a).value isa expected_type
                @test PSE.model_status(right.model,:a).value==expected_type(4)
                @test PSE.model_status(right.model,:b).value==expected_type(14)
                @test PSE.model_status(right.model,:c).value==expected_type(2)
                @test PSE.model_status(right.model,:a).payload!==PSE.model_status(right.model,:b).payload
                calls_after_growth=copy(right.trace)
                previous=_step_pair!(reference,candidate,previous)
                @test left.trace==right.trace==calls_after_growth
            else
                throw(ArgumentError("Unknown feature case $case"))
            end
            observed=_coverage(candidate)
            @test observed.typed_output_preparation.counters.objects_prepared>0
            @test observed.trusted_execution_index.counters.indices_certified>0
            push!(evidence,(case,coverage=observed,
                trusted_query_path_entered=observed.trusted_execution_index.counters.lookup_attempts>0))
        end
    end
    return (passed=true,outputs,evidence,benchmark_claim=false,
        oracle=:ordinary_exact_per_step_science_history_rng_refs_and_actual_feature_callbacks,
        generic_types=(:Float32,:converted_Float64,:BigFloat),
        trusted_coverage=:actual_certificate_and_query_counts_reported_no_invented_empty_slot_work)
end

end # module
