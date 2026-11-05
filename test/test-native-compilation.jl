using PlantSimEngine
using Test

PlantSimEngine.@process "native_compilation_source" verbose = false
PlantSimEngine.@process "native_compilation_reader" verbose = false
PlantSimEngine.@process "native_compilation_unsupported" verbose = false

struct NativeCompilationSource <: AbstractNative_Compilation_SourceModel
    increment::Float32
end

struct NativeCompilationReader <: AbstractNative_Compilation_ReaderModel end
struct NativeCompilationArray <: AbstractNative_Compilation_UnsupportedModel end
struct NativeCompilationDistributed <: AbstractNative_Compilation_UnsupportedModel end
struct NativeCompilationGrowth <: AbstractNative_Compilation_UnsupportedModel end
struct NativeCompilationWeather{Variable} <: AbstractNative_Compilation_UnsupportedModel end
struct NativeCompilationRemappedWeather <: AbstractNative_Compilation_UnsupportedModel end

PlantSimEngine.outputs_(::NativeCompilationSource) = (total=0.0f0,)
PlantSimEngine.inputs_(::NativeCompilationReader) = (incoming=Required(Float32),)
PlantSimEngine.outputs_(::NativeCompilationReader) = (observed=0.0f0,)
PlantSimEngine.outputs_(::NativeCompilationArray) = (samples=Float32[],)
PlantSimEngine.outputs_(::NativeCompilationDistributed) = (total=Distributed(Default(0.0f0)),)
PlantSimEngine.outputs_(::NativeCompilationGrowth) = (total=0.0f0,)
PlantSimEngine.outputs_(::NativeCompilationWeather{V}) where {V} = NamedTuple{(V,)}((0.0f0,))
PlantSimEngine.outputs_(::NativeCompilationRemappedWeather) = (remapped=0.0f0,)
PlantSimEngine.environment_inputs_(::NativeCompilationRemappedWeather) = (signal=0.0f0,)

function PlantSimEngine.run!(model::NativeCompilationSource, status, environment, constants, ::RunContext)
    status.total += model.increment
    return nothing
end

function PlantSimEngine.run!(::NativeCompilationReader, status, environment, constants, context::RunContext)
    status.observed = constants.scale * status.incoming + Float32(context.time)
    return nothing
end

function PlantSimEngine.run!(::NativeCompilationGrowth, status, environment, constants, context::RunContext)
    register_object!(runtime_model(context), Object(:new_organ; parent=:sample))
    return nothing
end

function PlantSimEngine.run!(::NativeCompilationWeather{V}, status, environment, constants, ::RunContext) where {V}
    status[V] += isnothing(environment) ? -1.0f0 : environment.signal
    return nothing
end

function PlantSimEngine.run!(::NativeCompilationRemappedWeather, status, environment, constants, ::RunContext)
    status.remapped += environment.signal
    return nothing
end

function native_compilation_scene(;
    every=nothing, previous=false, environment=nothing, extra_objects=(),
)
    object = Object(:sample; status=Status(total=2.0f0, incoming=0.0f0))
    source = One(within=Self(), application=:source, var=:total)
    inputs = (previous ? PreviousTimeStep(:incoming) : :incoming) => source
    return CompositeModel(
        object, extra_objects...;
        applications=(
            ModelSpec(NativeCompilationReader(); name=:reader, on=One(id=:sample), inputs=(inputs,)),
            ModelSpec(NativeCompilationSource(2.0f0); name=:source, on=One(id=:sample), every),
        ),
        environment,
    )
end

function native_compilation_rejection(f)
    exception = try
        f()
        nothing
    catch err
        err
    end
    @test exception isa ArgumentError
    return exception isa ArgumentError ? lowercase(sprint(showerror, exception)) : ""
end

@testset "Prepared native program matches ordinary PSE" begin
    constants = (scale=3.0f0,)
    authored = native_compilation_scene()
    authored_status = model_status(authored, :sample)
    before = NamedTuple(authored_status)
    split = Compilation.prepare(authored; constants)
    continuous = Compilation.prepare(authored; constants)
    expected = run!(native_compilation_scene(); steps=5, constants)

    @test current_step(split) == current_step(continuous) == 0
    @test final_state(split) == final_state(continuous)
    @test final_state(split).total === 2.0f0
    @test model_status(authored, :sample) === authored_status
    @test NamedTuple(authored_status) == before
    @test isnothing(Advanced.compiled_bindings(authored))

    step!(split)
    @test current_step(split) == 1
    @test final_state(split).total === 4.0f0
    @test final_state(split).observed === 13.0f0
    @test current_step(continuous) == 0
    @test final_state(continuous).total === 2.0f0

    continue!(split; steps=4)
    continue!(continuous; steps=5)
    @test current_step(split) == current_step(continuous) == current_step(expected) == 5
    @test final_state(split) == final_state(continuous) == final_state(expected)
    @test final_state(split).observed === 41.0f0
    @test NamedTuple(model_status(authored, :sample)) == before
end

@testset "Fixed environment rows use ordinary PSE bindings" begin
    function weather_scene(global_environment)
        on = One(id=:sample)
        return CompositeModel(Object(:sample); environment=global_environment, applications=(
            ModelSpec(NativeCompilationWeather{:local_read}(); name=:local_read, on,
                environment=Environment(backend=(signal=5.0f0,))),
            ModelSpec(NativeCompilationWeather{:default_read}(); name=:default_read, on),
            ModelSpec(NativeCompilationRemappedWeather(); name=:mapped, on,
                environment=Environment(backend=(air=2.0f0,), sources=(signal=:air,))),
        ))
    end

    for (environment, default_value) in ((nothing, -3.0f0), ((signal=7.0f0,), 21.0f0))
        compiled = Compilation.prepare(weather_scene(environment))
        step!(compiled)
        continue!(compiled; steps=2)
        ordinary = run!(weather_scene(environment); steps=3)
        @test final_state(compiled) == final_state(ordinary)
        @test final_state(compiled).local_read === 15.0f0
        @test final_state(compiled).remapped === 6.0f0
        @test final_state(compiled).default_read === default_value
    end
end

@testset "Preparation reports unsupported features" begin
    error = native_compilation_rejection() do
        Compilation.prepare(native_compilation_scene(; extra_objects=(Object(:other),)))
    end
    @test occursin("one object", error)

    empty_scene = CompositeModel(
        Object(:sample);
        applications=(ModelSpec(NativeCompilationSource(2.0f0); name=:source, on=Many(scale=:Leaf)),),
    )
    error = native_compilation_rejection(() -> Compilation.prepare(empty_scene))
    @test occursin("at least one scheduled application", error)

    error = native_compilation_rejection() do
        Compilation.prepare(native_compilation_scene(; every=2))
    end
    @test occursin("every step", error) && occursin(":source", error)

    error = native_compilation_rejection() do
        Compilation.prepare(native_compilation_scene(; previous=true))
    end
    @test occursin("temporal", error) && occursin(":reader", error)

    call_scene = CompositeModel(
        Object(:sample);
        applications=(
            ModelSpec(NativeCompilationGrowth(); name=:caller, on=One(id=:sample),
                calls=(source=One(within=Self(), application=:source),)),
            ModelSpec(NativeCompilationSource(2.0f0); name=:source, on=One(id=:sample)),
        ),
    )
    error = native_compilation_rejection(() -> Compilation.prepare(call_scene))
    @test occursin("calls or initializers", error) && occursin(":caller", error)

    error = native_compilation_rejection() do
        Compilation.prepare(native_compilation_scene(; environment=[(duration=1.0,)]))
    end
    @test occursin("environment", error)

    changing_provider = CompositeModel(Object(:sample); applications=(
        ModelSpec(NativeCompilationWeather{:local_read}(); name=:local_read, on=One(id=:sample),
            environment=Environment(backend=[(signal=5.0f0,)])),
    ))
    error = native_compilation_rejection(() -> Compilation.prepare(changing_provider))
    @test occursin("environment", error) && occursin(":local_read", error)

    array_scene = CompositeModel(
        Object(:sample);
        applications=(ModelSpec(NativeCompilationArray(); name=:array_writer, on=One(id=:sample)),),
    )
    error = native_compilation_rejection(() -> Compilation.prepare(array_scene))
    @test occursin("scalar", error) && occursin(":array_writer", error)

    stream_scene = CompositeModel(
        Object(:sample);
        applications=(ModelSpec(NativeCompilationSource(2.0f0); name=:stream_writer,
            on=One(id=:sample), output_routing=(total=:stream_only,)),),
    )
    error = native_compilation_rejection(() -> Compilation.prepare(stream_scene))
    @test occursin("stream-only", error) && occursin(":stream_writer", error)

    distributed_scene = CompositeModel(
        Object(:sample);
        applications=(ModelSpec(NativeCompilationDistributed(); name=:distributed_writer,
            on=One(id=:sample), outputs_to=(OutputTo(Many(within=Self())),)),),
    )
    error = native_compilation_rejection(() -> Compilation.prepare(distributed_scene))
    @test occursin("distributed", error) && occursin(":distributed_writer", error)

    live_scene = native_compilation_scene()
    run!(live_scene; steps=0, constants=(scale=3.0f0,))
    @test_throws ArgumentError Compilation.prepare(live_scene)
end

@testset "A prepared program rejects topology changes" begin
    authored = CompositeModel(
        Object(:sample);
        applications=(ModelSpec(NativeCompilationGrowth(); name=:growth, on=One(id=:sample)),),
    )
    program = Compilation.prepare(authored)
    error = native_compilation_rejection(() -> step!(program))
    @test occursin("topology", error)
    @test current_step(program) == 0
    @test length(model_objects(authored)) == 1
end

@testset "JuliaC is an optional build tool" begin
    if VERSION < v"1.13" || isnothing(Base.get_extension(PlantSimEngine, :PlantSimEngineJuliaCExt))
        mktempdir() do project
            write(joinpath(project, "Project.toml"), """
                name = "NativeCompilationFixture"
                uuid = "f98a294d-d7c1-4a84-b142-2f224810a587"
                version = "0.1.0"
                """)
            destination = joinpath(project, "bundle")
            error = native_compilation_rejection() do
                Compilation.compile(project; destination)
            end
            @test occursin(VERSION < v"1.13" ? "1.13" : "juliac", error)
            @test !ispath(destination)
        end
    end
end
