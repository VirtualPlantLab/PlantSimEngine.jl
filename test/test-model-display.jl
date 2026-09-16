using Dates

PlantSimEngine.@process "display_probe" verbose = false

struct DisplayProbeModel{T} <: AbstractDisplay_ProbeModel
    payload::T
end

PlantSimEngine.inputs_(::DisplayProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::DisplayProbeModel) = (count=0,)
function PlantSimEngine.run!(::DisplayProbeModel, status, environment, constants, context)
    status.count += 1
    return nothing
end

# Neither model parameters nor user-defined environment displays belong in the
# summary. A raw model must not be normalized through ModelSpec just to show it.
struct DisplayUnreadable end
Base.show(::IO, ::DisplayUnreadable) = error("Display must not read this value")

@testset "CompositeModel display does not prepare or run the model" begin
    model = CompositeModel(DisplayProbeModel(DisplayUnreadable()))
    status = model_status(model, :scene)
    revision = model.revision
    @test isnothing(model.binding_cache)
    @test repr(model) == "CompositeModel(objects=1, applications=1)"
    display = repr(MIME"text/plain"(), model)
    @test occursin("Objects: 1 (Scene: 1)", display)
    @test occursin("DisplayProbeModel", display)
    @test occursin("Shared environment: none", display)
    @test !occursin("DisplayUnreadable", display)
    @test isnothing(model.binding_cache)
    @test isnothing(model.environment_binding_cache)
    @test model.bindings_dirty
    @test model.revision == revision
    @test model_status(model, :scene) === status

    simulation = run!(model; steps=1)
    cache = model.binding_cache
    environment_cache = model.environment_binding_cache
    @test final_state(simulation).count == 1
    @test repr(MIME"text/plain"(), model) == display
    @test final_state(simulation).count == 1
    @test model.binding_cache === cache
    @test model.environment_binding_cache === environment_cache
    @test !model.bindings_dirty

    register_object!(model, Object(:leaf; scale=:Leaf))
    dirty_cache = model.binding_cache
    @test occursin("Objects: 2 (Leaf: 1, Scene: 1)", repr(MIME"text/plain"(), model))
    @test model.bindings_dirty
    @test model.binding_cache === dirty_cache

    # This setup cannot compile (no selector), but should still be inspectable.
    incomplete = CompositeModel(Object(:scene);
        applications=(DisplayProbeModel(DisplayUnreadable()),),
        environment=DisplayUnreadable())
    @test occursin("Shared environment: DisplayUnreadable", repr(MIME"text/plain"(), incomplete))
    @test isnothing(incomplete.binding_cache)
    @test occursin("Objects: 0", repr(MIME"text/plain"(), CompositeModel()))
end

@testset "CompositeModel display summarizes configuration" begin
    weather = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"))
    template = CompositeModelTemplate((
        ModelSpec(DisplayProbeModel(zeros(10_000)); name=:growth,
            on=Many(scale=:Leaf), every=Hour(1)),
    ))
    plant = Object(:plant; scale=:Plant)
    leaf = Object(:leaf; scale=:Leaf, parent=:plant)
    model = CompositeModel(
        ObjectInstance(:plant, template; root=plant, objects=(leaf,),
            object_overrides=(Override(object=:leaf, application=:growth,
                model=DisplayProbeModel(ones(10_000))),));
        environment=weather,
    )
    display = repr(MIME"text/plain"(), model)
    @test repr(model) == "CompositeModel(objects=2, applications=1, instances=1)"
    @test occursin("Objects: 2 (Leaf: 1, Plant: 1)", display)
    @test occursin("Template instances: 1", display)
    @test occursin("TimeStepTable (365 rows)", display)
    @test occursin("plant__growth: DisplayProbeModel (1 object override); every 1 hour", display)
    @test !occursin("ObjectModelOverrides", display)
    @test length(display) < 500
    @test repr(MIME"text/plain"(), model; context=:compact => true) == repr(model)
    @test count(repr(model), repr([model, model])) == 2
end

@testset "CompositeModel display stays small" begin
    applications = [ModelSpec(DisplayProbeModel(zeros(100));
        name=Symbol("growth_", index), on=Many(scale=:Leaf)) for index in 1:100]
    model = CompositeModel((Object(index; scale=:Leaf) for index in 1:100)...;
        applications=applications)
    display = repr(MIME"text/plain"(), model)
    @test occursin("Objects: 100 (Leaf: 100)", display)
    @test occursin("Model applications: 100", display)
    @test occursin("92 more", display)
    @test length(split(display, '\n')) <= 13
    @test length(display) < 1000

    pushfirst!(model.applications, ModelSpec(DisplayProbeModel(0);
        name=Symbol(repeat("叶", 50), "\nnext line"), on=Many(scale=:Leaf)))
    small = sprint(show, MIME"text/plain"(), model;
        context=(:limit => true, :displaysize => (10, 32)))
    @test length(split(small, '\n')) <= 10
    @test all(line -> textwidth(line) <= 32, split(small, '\n'))
    @test occursin("…", small)
    @test occursin("96 more", small)
end
