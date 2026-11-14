module ExecutionBatchTimeChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

struct WrappedTime <: Real
    value::Float32
end
Base.float(time::WrappedTime) = time.value
mutable struct Backend <: EA.AbstractEnvironmentBackend
    samples::Vector{Symbol}
end
EA.base_step_seconds(::Backend) = 1.0
EA.get_nsteps(::Backend) = 8
EA.environment_variables(::Backend) = Set((:T,))
EA.bind_environment(::Backend, object::Object, context, config) = nothing
function sample_value(backend, kind, value)
    push!(backend.samples, kind)
    return value
end
EA.sample(backend::Backend, handle, variable::Symbol, ::Integer) =
    sample_value(backend, :integer, 10.0f0)
EA.sample(backend::Backend, handle, variable::Symbol, ::Float32) =
    sample_value(backend, :float32, 20.0f0)
EA.sample(backend::Backend, handle, variable::Symbol, ::Float64) =
    sample_value(backend, :float64, 30.0f0)
EA.sample(backend::Backend, handle, variable::Symbol, ::WrappedTime) =
    sample_value(backend, :wrapped, 40.0f0)

PSE.@process "execution_time_source" verbose=false
PSE.@process "execution_time_consumer" verbose=false
PSE.@process "execution_time_controller" verbose=false
PSE.@process "execution_time_leaf" verbose=false
struct Source <: AbstractExecution_Time_SourceModel end
struct Consumer <: AbstractExecution_Time_ConsumerModel end
struct Controller <: AbstractExecution_Time_ControllerModel end
struct Leaf <: AbstractExecution_Time_LeafModel end
PSE.inputs_(::Union{Source,Controller,Leaf}) = NamedTuple()
PSE.inputs_(::Consumer) = (signal=Required(Float32),)
PSE.outputs_(::Source) = (signal=0.0f0, env_tag=0.0f0, context_time=0.0)
PSE.outputs_(::Consumer) = (observed=0.0f0, env_tag=0.0f0, context_time=0.0)
PSE.outputs_(::Union{Controller,Leaf}) = (seen=0.0f0, calls=0, context_time=0.0)
PSE.environment_inputs_(::Union{Source,Consumer,Controller,Leaf}) = (T=0.0f0,)
function PSE.run!(::Source, status, environment, constants, context)
    status.signal += environment.T
    status.env_tag = environment.T
    status.context_time = context.time
    return nothing
end
function PSE.run!(::Consumer, status, environment, constants, context)
    status.observed = status.signal
    status.env_tag = environment.T
    status.context_time = context.time
    return nothing
end
function PSE.run!(::Controller, status, environment, constants, context)
    status.seen = environment.T
    status.calls += 1
    status.context_time = context.time
    run_call!(context, :leaf; publish=true)
    return nothing
end
function PSE.run!(::Leaf, status, environment, constants, context)
    status.seen = environment.T
    status.calls += 1
    status.context_time = context.time
    return nothing
end
function temporal_fixture(performance)
    backend = Backend(Symbol[])
    model = CompositeModel(Object(:source; scale=:Source, status=Status(signal=0.0f0)),
        Object(:consumer; scale=:Consumer, status=Status(signal=0.0f0));
        applications=(
            ModelSpec(Source(); name=:source, on=One(id=:source)),
            ModelSpec(Consumer(); name=:consumer, on=One(id=:consumer),
                inputs=(PreviousTimeStep(:signal) => One(SceneScope(); id=:source, application=:source, var=:signal))),
        ), environment=backend)
    simulation = run!(model; steps=3, outputs=:all, performance)
    return (; model, simulation, backend)
end
batch_for(simulation, application) = only(batch for batch in simulation.execution_plan.batches
    if batch.application.id === application)
function execute_prepared!(data, application, time)
    simulation = data.simulation
    return PSE._run_model_execution_batch!(batch_for(simulation, application),
        simulation.compiled, simulation.environment_bindings, time,
        simulation.constants, simulation.temporal_streams, simulation.output_retention,
        simulation.performance)
end

@testset "one batch loop preserves temporal materialization and output publication" begin
    for performance in (false, true)
        data = temporal_fixture(performance)
        @test data.backend.samples == fill(:float64, 6)
        @test outputs(data.simulation)[(:source, ObjectId(:source), :signal)] ==
            [(1.0, 30.0f0), (2.0, 60.0f0), (3.0, 90.0f0)]
        @test outputs(data.simulation)[(:consumer, ObjectId(:consumer), :observed)] ==
            [(1.0, 0.0f0), (2.0, 30.0f0), (3.0, 60.0f0)]
        @test model_status(data.model, :source).context_time === 3.0
        @test model_status(data.model, :consumer).context_time === 3.0
        execute_prepared!(data, :source, 4.0f0)
        execute_prepared!(data, :consumer, 4.0f0)
        @test data.backend.samples[end-1:end] == [:float32, :float32]
        @test model_status(data.model, :source).signal === 110.0f0
        @test model_status(data.model, :consumer).observed === 90.0f0
        @test model_status(data.model, :consumer).env_tag === 20.0f0
        @test model_status(data.model, :consumer).context_time === 4.0
        @test last(outputs(data.simulation)[(:consumer, ObjectId(:consumer), :observed)]) == (4.0, 90.0f0)
        # float(time) defines the prepared clock without requiring a direct
        # Float64 conversion from an arbitrary Real wrapper. Float32 is kept
        # for model-facing sampling and converted only in context storage.
        execute_prepared!(data, :source, WrappedTime(5.0f0))
        @test last(data.backend.samples) === :float32
        @test model_status(data.model, :source).signal === 130.0f0
        @test model_status(data.model, :source).context_time === 5.0
        @test last(outputs(data.simulation)[(:source, ObjectId(:source), :signal)]) == (5.0, 130.0f0)
        if performance
            counters = PSE.Advanced.runtime_performance(data.simulation)
            @test all(haskey(counters.elapsed_seconds, metric) for metric in (
                :temporal_input_materialization, :environment_sampling,
                :scientific_kernel_execution, :output_publication))
        end
    end
end

@testset "prepared batches without temporal storage retain their context factory" begin
    backend = Backend(Symbol[])
    model = CompositeModel(Object(:source; scale=:Source, status=Status(signal=0.0f0));
        applications=(ModelSpec(Source(); name=:source, on=One(id=:source)),), environment=backend)
    compiled = PSE.Advanced.refresh_bindings!(model)
    environment = PSE.Advanced.refresh_environment_bindings!(model, compiled)
    plan = PSE.compile_model_execution_plan(compiled, environment)
    batch = only(plan.batches)
    @test isnothing(only(batch.targets).context)
    PSE._run_model_execution_batch!(batch, compiled, environment, 1, nothing, nothing, nothing)
    @test backend.samples == [:float64]
    @test model_status(model, :source).signal === 30.0f0
    @test model_status(model, :source).context_time === 1.0
    PSE._run_model_execution_batch!(batch, compiled, environment, 2.0f0, nothing, nothing, nothing)
    @test last(backend.samples) === :float32
    @test model_status(model, :source).signal === 50.0f0
    @test model_status(model, :source).context_time === 2.0
end

@testset "ordinary controllers retain their hard-call clocks and publication" begin
    for performance in (false, true)
        backend = Backend(Symbol[])
        model = CompositeModel(Object(:owner; scale=:Scene), Object(:leaf; scale=:Leaf, parent=:owner);
            applications=(
                ModelSpec(Controller(); name=:controller, on=One(id=:owner),
                    calls=(leaf=One(id=:leaf, application=:leaf),)),
                ModelSpec(Leaf(); name=:leaf, on=One(id=:leaf)),
            ), environment=backend)
        simulation = run!(model; steps=2, outputs=:all, performance)
        @test backend.samples == fill(:float64, 4)
        @test model_status(model, :owner).seen === 30.0f0
        @test model_status(model, :owner).calls == 2
        @test model_status(model, :leaf).seen === 30.0f0
        @test model_status(model, :leaf).calls == 2
        @test model_status(model, :leaf).context_time === 2.0
        @test outputs(simulation)[(:leaf, ObjectId(:leaf), :seen)] == [(1.0, 30.0f0), (2.0, 30.0f0)]
    end
end

@testset "public retention choice does not change sampling dispatch" begin
    values = Float32[]
    sampled_kinds = Vector{Symbol}[]
    for retained in (:none, :all)
        backend = Backend(Symbol[])
        model = CompositeModel(Object(:source; scale=:Source);
            applications=(ModelSpec(Source(); name=:source, on=One(id=:source)),), environment=backend)
        simulation = run!(model; steps=1, outputs=retained)
        @test simulation.temporal_streams isa PSE.RuntimeStorage
        push!(values, model_status(model, :source).signal)
        push!(sampled_kinds, backend.samples)
    end
    @test values[1] === values[2]
    @test sampled_kinds == [[:float64], [:float64]]
    @test values == [30.0f0, 30.0f0]
end
end
