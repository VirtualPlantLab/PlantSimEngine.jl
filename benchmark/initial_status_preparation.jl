module InitialStatusPreparationBenchmark

using PlantSimEngine

# Compilation workload, not a scientific model: a wide schema with no kernel work.
PlantSimEngine.@process "initial_status_preparation_benchmark" verbose=false

struct WideDefaults{N} <: AbstractInitial_Status_Preparation_BenchmarkModel end

PlantSimEngine.outputs_(::WideDefaults{N}) where {N} = NamedTuple{
    ntuple(i -> Symbol("output_", i), N)
}(ntuple(_ -> 0.0, N))
PlantSimEngine.inputs_(::WideDefaults{N}) where {N} = NamedTuple{
    ntuple(i -> Symbol("input_", i), N)
}(ntuple(_ -> Default(1.0), N))
PlantSimEngine.run!(::WideDefaults, status, environment, constants, context) = nothing

function scenario(n; objects=1)
    return CompositeModel(
        (Object(Symbol("object_", i); scale=:Benchmark, status=Status(seed=2.0))
         for i in 1:objects)...;
        applications=(ModelSpec(WideDefaults{n}(); on=Many(scale=:Benchmark)),),
    )
end

"""
Measure construction, first run, an equivalent warm run, and continued stepping.
Use a fresh Kaimon session for each revision and the same `n`, object count,
Julia version, manifest, and output retention. Do not sum overlapping timings.
Returned byte counts are cumulative allocations, not peak resident memory.
"""
function measure(n=64; objects=1, warm_steps=100)
    construction = @timed scenario(n; objects)
    first_run = @timed run!(construction.value; steps=1, outputs=:none)
    warm_construction = @timed scenario(n; objects)
    warm_run = @timed run!(warm_construction.value; steps=1, outputs=:none)
    continuation = @timed continue!(warm_run.value; steps=warm_steps)
    return (
        fields_per_object=2n + 1, objects,
        construction=(seconds=construction.time, bytes=construction.bytes),
        first_run=(seconds=first_run.time, bytes=first_run.bytes),
        warm_construction=(seconds=warm_construction.time, bytes=warm_construction.bytes),
        warm_run=(seconds=warm_run.time, bytes=warm_run.bytes),
        continuation=(steps=warm_steps, seconds=continuation.time, bytes=continuation.bytes),
    )
end

# A second compilation workload: many distinct application/view types share one
# wide canonical Status. The simple counters below have no scientific meaning.
PlantSimEngine.@process "status_binding_signal_benchmark" verbose=false
PlantSimEngine.@process "status_binding_readout_benchmark" verbose=false

struct IncrementSignal{T} <: AbstractStatus_Binding_Signal_BenchmarkModel
    increment::T
end

PlantSimEngine.inputs_(::IncrementSignal) = NamedTuple()
PlantSimEngine.outputs_(model::IncrementSignal) = (signal=zero(model.increment),)

function PlantSimEngine.run!(model::IncrementSignal, status, environment, constants, context)
    status.signal += model.increment
    return nothing
end

struct BoundReadout{Names,Output,T} <: AbstractStatus_Binding_Readout_BenchmarkModel
    offset::T
end

function PlantSimEngine.inputs_(::BoundReadout{Names}) where {Names}
    declarations = ntuple(length(Names)) do j
        mod(j, 4) in (0, 3) ? Required(AbstractVector{<:Real}) : Required(Real)
    end
    return NamedTuple{Names}(declarations)
end

PlantSimEngine.outputs_(model::BoundReadout{Names,Output}) where {Names,Output} =
    NamedTuple{(Output,)}((zero(model.offset),))

function PlantSimEngine.run!(
    model::BoundReadout{Names,Output}, status, environment, constants, context,
) where {Names,Output}
    total = model.offset
    for name in Names
        value = getproperty(status, name)
        total += value isa Real ? value : sum(value; init=zero(model.offset))
    end
    setproperty!(status, Output, total)
    return nothing
end

readout_names(i) = ntuple(j -> Symbol("readout_", i, "_input_", j), 2 + mod(i - 1, 4))
readout_output(i) = Symbol("readout_", i, "_total")

# Alternate canonical scalar, lagged scalar, current Many, and lagged Many.
# Distinct port names and arities yield distinct concrete model and view types
# without generating Julia source or calling compiler-internal APIs.
function readout_binding(name, j, width)
    kind = mod(j, 4)
    if kind == 1
        return name => One(within=Self(), var=Symbol("seed_", mod1(j, width)))
    elseif kind == 2
        return PreviousTimeStep(name) => One(
            scale=:Source, name=:source_1, within=Subtree(),
            application=:signal_source, var=:signal,
        )
    end
    selector = Many(
        scale=:Source, within=Subtree(), application=:signal_source, var=:signal,
    )
    return kind == 0 ? (PreviousTimeStep(name) => selector) : (name => selector)
end

function binding_scenario(width=96; applications=12, sources=4, T=Float64)
    width > 0 && applications > 0 && sources > 0 ||
        throw(ArgumentError("width, applications, and sources must be positive"))
    padding = NamedTuple{ntuple(j -> Symbol("seed_", j), width)}(
        ntuple(_ -> one(T), width),
    )
    # Explicit initial values make the temporal semantics independent of
    # scheduling and keep the first previous-timestep sample equal to zero.
    initial_lags = (;
        (name => (mod(j, 4) == 2 ? zero(T) : zeros(T, sources))
         for i in 1:applications for (j, name) in enumerate(readout_names(i))
         if mod(j, 4) in (0, 2))...,
    )
    readouts = ntuple(applications) do i
        names = readout_names(i)
        ModelSpec(
            BoundReadout{names,readout_output(i),T}(zero(T));
            name=Symbol("readout_", i), on=One(scale=:Collector),
            inputs=Tuple(readout_binding(name, j, width) for (j, name) in enumerate(names)),
        )
    end
    return CompositeModel(
        Object(:collector; scale=:Collector, status=Status(merge(padding, initial_lags))),
        (Object(Symbol("source_", i); scale=:Source, name=Symbol("source_", i),
            parent=:collector, status=Status(signal=zero(T))) for i in 1:sources)...;
        applications=(
            ModelSpec(IncrementSignal(one(T)); name=:signal_source, on=Many(scale=:Source)),
            readouts...,
        ),
    )
end

function check_binding_readouts(model, step, applications, sources)
    status = only(model_objects(model; scale=:Collector)).status
    for i in 1:applications
        expected = sum(eachindex(readout_names(i))) do j
            kind = mod(j, 4)
            kind == 1 ? 1 : kind == 2 ? step - 1 :
            kind == 3 ? sources * step : sources * (step - 1)
        end
        @assert getproperty(status, readout_output(i)) == expected
    end
    @assert all(object.status.signal == step for object in model_objects(model; scale=:Source))
    return nothing
end

"""
    measure_bindings(width=96; applications=12, sources=4, warm_steps=100, T=Float64)

Measure initial status preparation and application-view assembly together. The
default is five objects: one wide collector, four incrementing sources, and
twelve differently typed readout applications with two to five bindings each.
Bindings cover canonical fields, `One`, `Many`, and `PreviousTimeStep` on both
scalar and Many sources. Numerical assertions run outside the measured regions.

In a fresh Kaimon session for the revision being compared, include this file and
call `InitialStatusPreparationBenchmark.measure_bindings()`. Use a separate
fresh session for the existing `measure()` workload so its compilation does not
warm this one. Keep arguments, Julia version, manifest and output retention
identical on the parent and patched revision. Package loading is not timed.

Construction and first run report the cold phases; a newly built equivalent
scenario reports warmed construction/run; `continue!` measures steady stepping
without restarting the timeline. `outputs=:none` still retains streams needed
by temporal bindings. Bytes are cumulative allocations, not peak memory. There
are no timing thresholds and this benchmark is not a MAESPA simulation.
"""
function measure_bindings(width=96; applications=12, sources=4, warm_steps=100, T=Float64)
    warm_steps > 0 || throw(ArgumentError("warm_steps must be positive"))
    construction = @timed binding_scenario(width; applications, sources, T)
    first_run = @timed run!(construction.value; steps=1, outputs=:none)
    check_binding_readouts(construction.value, 1, applications, sources)
    warm_construction = @timed binding_scenario(width; applications, sources, T)
    warm_run = @timed run!(warm_construction.value; steps=1, outputs=:none)
    check_binding_readouts(warm_construction.value, 1, applications, sources)
    continuation = @timed continue!(warm_run.value; steps=warm_steps)
    check_binding_readouts(warm_construction.value, warm_steps + 1, applications, sources)
    return (
        seed_fields=width,
        canonical_fields=length(only(model_objects(construction.value; scale=:Collector)).status),
        objects=sources + 1, applications=applications + 1, numeric_type=T,
        readout_bindings=sum(length(readout_names(i)) for i in 1:applications),
        construction=(seconds=construction.time, bytes=construction.bytes),
        first_run=(seconds=first_run.time, bytes=first_run.bytes),
        warm_construction=(seconds=warm_construction.time, bytes=warm_construction.bytes),
        warm_run=(seconds=warm_run.time, bytes=warm_run.bytes),
        continuation=(steps=warm_steps, seconds=continuation.time, bytes=continuation.bytes),
    )
end

end # module
