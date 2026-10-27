module PreparedEnvironmentInputChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine
const EA = PlantSimEngine.EnvironmentAPI

mutable struct PreparedInputBackend{T} <: EA.AbstractEnvironmentBackend
    temperatures::Vector{T}
end
mutable struct PreparedInputTrial{T}
    temperatures::Vector{T}
end
EA.base_step_seconds(::PreparedInputBackend) = 3600.0
EA.get_nsteps(::PreparedInputBackend) = 4
EA.environment_variables(::PreparedInputBackend) = Set((:source_temperature, :clock_index))
function EA.bind_environment(::PreparedInputBackend, object::PSE.Object, context, config)
    @assert config.provider === :prepared_probe
    return (index=geometry(object).index, provider=config.provider)
end
function EA.sample(backend::PreparedInputBackend{T}, handle, variable::Symbol, time) where {T}
    @assert handle.provider === :prepared_probe
    variable === :source_temperature && return backend.temperatures[handle.index]
    variable === :clock_index && return T(time)
    error("Unexpected prepared input $variable")
end
function EA.sample(::PreparedInputBackend{T}, handle, trial::PreparedInputTrial,
                   variable::Symbol, time) where {T}
    @assert handle.provider === :prepared_probe
    variable === :source_temperature && return trial.temperatures[handle.index]
    variable === :clock_index && return T(time)
    error("Unexpected prepared trial input $variable")
end

PSE.@process "prepared_environment_input_probe" verbose=false
struct PreparedInputProbe{T} <: AbstractPrepared_Environment_Input_ProbeModel end
PSE.inputs_(::PreparedInputProbe) = NamedTuple()
PSE.outputs_(::PreparedInputProbe{T}) where {T} = (seen=zero(T), seen_time=zero(T))
PSE.environment_inputs_(::PreparedInputProbe{T}) where {T} = (T=zero(T), clock_index=zero(T))
function PSE.run!(::PreparedInputProbe, status, environment, constants, context)
    status.seen = environment.T
    status.seen_time = environment.clock_index
    return nothing
end

function prepared_scene(::Type{T}) where {T}
    backend = PreparedInputBackend(T[10, 20])
    spec = ModelSpec(PreparedInputProbe{T}(); name=:probe, on=Many(scale=:Leaf),
        environment=Environment(provider=:prepared_probe, sources=(T=:source_temperature,)))
    model = CompositeModel(
        Object(:left; scale=:Leaf, geometry=(index=1,)),
        Object(:right; scale=:Leaf, geometry=(index=2,));
        applications=(spec,), environment=backend)
    return (; model, backend, spec)
end

# A backend can validate a mutable trial once and return one already prepared
# snapshot shared by several targets. Specializing this batch hook must take
# precedence over per-variable sampling, both directly and in the runtime.
struct SharedPreparedSnapshotBackend{T} <: EA.AbstractEnvironmentBackend
    snapshot::Base.RefValue{T}
    batches::Base.RefValue{Int}
end
EA.base_step_seconds(::SharedPreparedSnapshotBackend) = 3600.0
EA.get_nsteps(::SharedPreparedSnapshotBackend) = 4
EA.environment_variables(::SharedPreparedSnapshotBackend) = Set((:source_temperature, :clock_index))
EA.bind_environment(::SharedPreparedSnapshotBackend, object::PSE.Object, context, config) = nothing
function EA.sample_environment(backend::SharedPreparedSnapshotBackend, handle, time,
                               inputs::PSE.PreparedEnvironmentInputs)
    @assert keys(inputs) == (:T, :clock_index)
    @assert values(inputs) == (:source_temperature, :clock_index)
    backend.batches[] += 1
    return backend.snapshot[]
end
function EA.sample_environment(backend::SharedPreparedSnapshotBackend, handle,
                               state::Base.RefValue, time, inputs::PSE.PreparedEnvironmentInputs)
    @assert keys(inputs) == (:T, :clock_index)
    backend.batches[] += 1
    return state[]
end

function changing_trial_sum(backend, handle, state, inputs, count)
    total = zero(eltype(state.temperatures))
    for index in 1:count
        state.temperatures[handle.index] += one(total)
        total += EA.sample_environment(backend, handle, state, 1.0, inputs).T
    end
    return total
end
function changing_committed_sum(backend, handle, inputs, count)
    total = zero(eltype(backend.temperatures))
    for index in 1:count
        backend.temperatures[handle.index] += one(total)
        total += EA.sample_environment(backend, handle, 1.0, inputs).T
    end
    return total
end

@testset "Prepared environment schemas preserve handles and changing values" begin
    @test_throws ArgumentError PSE.PreparedEnvironmentInputs((:T,), ())
    @test_throws ArgumentError PSE.PreparedEnvironmentInputs((:T, :T), (:a, :b))
    @test_throws ArgumentError PSE.PreparedEnvironmentInputs((:T,), (1,))
    for T in (Float32, Float64)
        scene = prepared_scene(T)
        simulation = run!(scene.model; steps=1)
        @test final_state(simulation, One(id=:left)) == (seen=T(10), seen_time=T(1))
        @test final_state(simulation, One(id=:right)) == (seen=T(20), seen_time=T(1))
        inputs = PSE.PreparedEnvironmentInputs(scene.spec)
        @test keys(inputs) == (:T, :clock_index)
        @test values(inputs) == (:source_temperature, :clock_index)
        handle = (index=2, provider=:prepared_probe)
        trial = PreparedInputTrial(T[30, 40])
        @test EA.sample_environment(scene.backend, handle, trial, 2.0, inputs) ==
              (T=T(40), clock_index=T(2))
        trial.temperatures[2] = T(44)
        @test EA.sample_environment(scene.backend, handle, trial, 2.0, inputs).T === T(44)
        scene.backend.temperatures[2] = T(22)
        @test EA.sample_environment(scene.backend, handle, 2.0, inputs).T === T(22)
        binding = simulation.environment_bindings.by_target[(:probe, ObjectId(:right))]
        application = simulation.compiled.applications_by_id[:probe]
        @test PSE._model_environment_for_binding(simulation.environment_bindings,
            application, binding, 2.0, trial).T === T(44)
        trial.temperatures[2] = T(45)
        @test PSE._model_environment_for_binding(simulation.environment_bindings,
            application, binding, 2.0, trial).T === T(45)
        @test PSE._model_environment_for_binding(simulation.environment_bindings,
            application, binding, 2.0).T === T(22)
        @test EA.sample_environment(scene.backend, handle, trial, 1.0,
            PSE.PreparedEnvironmentInputs((), ())) == NamedTuple()

        # Prepared scalar sampling has no allocation proportional to invocations.
        # Warm the exact committed and transient specializations first.
        changing_trial_sum(scene.backend, handle, trial, inputs, 4)
        changing_committed_sum(scene.backend, handle, inputs, 4)
        @test @allocated(changing_trial_sum(scene.backend, handle, trial, inputs, 1_000)) == 0
        @test @allocated(changing_committed_sum(scene.backend, handle, inputs, 1_000)) == 0
    end
end

@testset "Prepared batch backends share a current snapshot" begin
    row = (T=12.0, clock_index=1.0)
    backend = SharedPreparedSnapshotBackend(Ref(row), Ref(0))
    spec = ModelSpec(PreparedInputProbe{Float64}(); name=:probe, on=Many(scale=:Leaf),
        environment=Environment(sources=(T=:source_temperature,)))
    model = CompositeModel(Object(:a; scale=:Leaf), Object(:b; scale=:Leaf);
        applications=(spec,), environment=backend)
    simulation = run!(model; steps=1)
    @test final_state(simulation, One(id=:a)).seen == 12.0
    @test final_state(simulation, One(id=:b)).seen == 12.0
    before = backend.batches[]
    backend.snapshot[] = (T=15.0, clock_index=2.0)
    step!(simulation)
    @test backend.batches[] == before + 2
    @test final_state(simulation, One(id=:a)).seen == 15.0
    trial = Ref((T=20.0, clock_index=3.0))
    binding = simulation.environment_bindings.by_target[(:probe, ObjectId(:a))]
    application = simulation.compiled.applications_by_id[:probe]
    @test PSE._model_environment_for_binding(simulation.environment_bindings,
        application, binding, 3.0, trial) === trial[]
    trial[] = (T=21.0, clock_index=3.0)
    @test PSE._model_environment_for_binding(simulation.environment_bindings,
        application, binding, 3.0, trial) === trial[]
    @test EA.sample_environment(backend, nothing, 2.0, spec) === backend.snapshot[]
end

@testset "Prepared global sampling preserves raw rows and duration remapping" begin
    row = (source_temperature=18.0, clock_index=1.0, duration=Hour(1), alternate_duration=Hour(2))
    backend = EA.GlobalConstant(row)
    raw_spec = ModelSpec(PreparedInputProbe{Float64}())
    @test EA.sample_environment(backend, nothing, 1.0,
        PSE.PreparedEnvironmentInputs(raw_spec)) === row
    mapped_spec = ModelSpec(PreparedInputProbe{Float64}();
        environment=Environment(sources=(T=:source_temperature,)))
    mapped = PSE.PreparedEnvironmentInputs(mapped_spec)
    @test EA.sample_environment(backend, nothing, 1.0, mapped) ==
          (T=18.0, clock_index=1.0, duration=Hour(1))
    changed = merge(row, (source_temperature=19.0,))
    @test EA.sample_environment(backend, nothing, changed, 1.0, mapped).T == 19.0
    duration_schema = PSE.PreparedEnvironmentInputs((:T, :duration),
        (:source_temperature, :alternate_duration))
    @test EA.sample_environment(backend, nothing, 1.0, duration_schema) ==
          (T=18.0, duration=Hour(2))
end

end # module
