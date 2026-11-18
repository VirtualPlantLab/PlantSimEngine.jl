module DistributedGrowthFixture

import PlantSimEngine as PSE

PSE.@process "mini_weather_grower" verbose=false
PSE.@process "mini_weather_leaf_source" verbose=false
PSE.@process "mini_weather_lag_reader" verbose=false
PSE.@process "mini_weather_distributor" verbose=false
struct Grower <: AbstractMini_Weather_GrowerModel end
struct LeafSource <: AbstractMini_Weather_Leaf_SourceModel end
struct LagReader <: AbstractMini_Weather_Lag_ReaderModel end
struct Distributor{VARIABLE} <: AbstractMini_Weather_DistributorModel
    factor::Float32
end
PSE.inputs_(::Grower) = NamedTuple()
PSE.outputs_(::Grower) = (visits=0, seen=0.0, dose=0.0)
PSE.environment_inputs_(::Grower) = (T=0.0,)
PSE.inputs_(::LeafSource) = (tick=PSE.Default(0),)
PSE.outputs_(::LeafSource) = (x=0f0,)
PSE.inputs_(::LagReader) = (tick=PSE.Default(0), lag=PSE.Default(Float32[]))
PSE.outputs_(::LagReader) = (lagtotal=0f0,)
PSE.inputs_(::Distributor) = (tick=PSE.Default(0),)
PSE.outputs_(::Distributor{VARIABLE}) where {VARIABLE} =
    NamedTuple{(VARIABLE,)}((PSE.Distributed(PSE.Default(0f0)),))
PSE.environment_inputs_(::Distributor) = (T=0.0,)
leaf_status(value::Float32) = PSE.Status(x=value, tick=0)
function PSE.run!(::Grower, status, environment, constants, context)
    status.visits += 1
    status.seen = environment.T
    status.dose += environment.T
    if status.visits == 2
        model = PSE.runtime_model(context)
        # Both signals are first supplied at birth. The root distributor is
        # already running, and the emitter distributor becomes active below.
        supplied = PSE.Status(x=10f0, tick=0, delivered=-7f0, prospective=-11f0)
        PSE.register_object!(model, PSE.Object(:leaf_b;
            scale=:Leaf, parent=:root, status=supplied))
        PSE.register_object!(model, PSE.Object(:emitter;
            scale=:Emitter, parent=:root, status=PSE.Status(tick=0)))
    end
    return nothing
end
PSE.run!(::LeafSource, status, environment, constants, context) =
    (status.x += 1f0; nothing)
PSE.run!(::LagReader, status, environment, constants, context) =
    (status.lagtotal = sum(PSE.bound_input(context, :lag); init=0f0); nothing)
function PSE.run!(model::Distributor{VARIABLE}, status, environment, constants, context) where {VARIABLE}
    destinations = PSE.output_targets(context, (VARIABLE,))
    column = getproperty(destinations.columns, VARIABLE)
    for index in eachindex(PSE.object_ids(destinations))
        column[index] = model.factor * Float32(environment.T)
    end
    return nothing
end

function hourly_weather()
    weather = PSE.PlantMeteo.Weather([
        PSE.PlantMeteo.Atmosphere(date=PSE.Dates.DateTime(2025, 1, 1) + PSE.Dates.Hour(index - 1),
            T=temperature, Wind=1.0, Rh=0.5, duration=PSE.Dates.Hour(1))
        for (index, temperature) in enumerate((10.0, 20.0, 30.0, 40.0))
    ])
    return weather
end

function make_model(; reader_every=PSE.Dates.Hour(1), distributor_every=PSE.Dates.Hour(1))
    weather = hourly_weather()
    root = PSE.Object(:root; scale=:Scene,
        status=PSE.Status(visits=0, seen=0.0, dose=0.0, tick=0, lag=Float32[], lagtotal=0f0))
    leaf = PSE.Object(:leaf_a; scale=:Leaf, parent=:root, status=leaf_status(1f0))
    model = PSE.CompositeModel(root, leaf; environment=weather, applications=(
        PSE.ModelSpec(Grower(); name=:grower, on=PSE.One(id=:root), every=PSE.Dates.Hour(1)),
        # This genuine One input orders growth before sources so B runs on its birth step.
        PSE.ModelSpec(LeafSource(); name=:source, on=PSE.Many(scale=:Leaf), every=PSE.Dates.Hour(1),
            inputs=(:tick => PSE.One(id=:root, within=PSE.SceneScope(), application=:grower, var=:visits),)),
        PSE.ModelSpec(LagReader(); name=:reader, on=PSE.One(id=:root), every=reader_every,
            inputs=(:tick => PSE.One(id=:root, within=PSE.SceneScope(), application=:grower, var=:visits),
                PSE.PreviousTimeStep(:lag) => PSE.Many(PSE.SceneScope(); scale=:Leaf,
                    application=:source, var=:x))),
        PSE.ModelSpec(Distributor{:delivered}(1f0); name=:distributed,
            on=PSE.One(id=:root), every=distributor_every,
            inputs=(:tick => PSE.One(id=:root, within=PSE.SceneScope(), application=:grower, var=:visits),),
            outputs_to=(PSE.OutputTo(PSE.Many(PSE.SceneScope(); scale=:Leaf); vars=(:delivered,)),)),
        PSE.ModelSpec(Distributor{:prospective}(2f0); name=:prospective_distributor,
            on=PSE.Many(scale=:Emitter), every=PSE.Dates.Hour(1),
            inputs=(:tick => PSE.One(id=:root, within=PSE.SceneScope(), application=:grower, var=:visits),),
            outputs_to=(PSE.OutputTo(PSE.Many(PSE.SceneScope(); scale=:Leaf); vars=(:prospective,)),)),
    ))
    return model
end

# A producer is born while every one of its thirty destinations already exists.
PSE.@process "distributed_producer_birth" verbose=false
struct ProducerBirth <: AbstractDistributed_Producer_BirthModel end
PSE.inputs_(::ProducerBirth) = NamedTuple()
PSE.outputs_(::ProducerBirth) = (visits=0,)
function PSE.run!(::ProducerBirth, status, environment, constants, context)
    status.visits += 1
    if status.visits == 2
        PSE.register_object!(PSE.runtime_model(context), PSE.Object(:emitter;
            scale=:Emitter, parent=:root, status=PSE.Status(tick=0)))
    end
    return nothing
end

producer_birth_leaf_ids() = [PSE.ObjectId(Symbol(:leaf_, index)) for index in 1:30]
function make_producer_birth_model()
    objects = PSE.Object[PSE.Object(:root; scale=:Scene, status=PSE.Status(visits=0))]
    for (index, id) in enumerate(producer_birth_leaf_ids())
        push!(objects, PSE.Object(id; scale=:Leaf, parent=:root, status=PSE.Status(ordinal=index)))
    end
    return PSE.CompositeModel(objects...; environment=hourly_weather(), applications=(
        PSE.ModelSpec(ProducerBirth(); name=:birth, on=PSE.One(id=:root), every=PSE.Dates.Hour(1)),
        PSE.ModelSpec(Distributor{:signal}(2f0); name=:producer,
            on=PSE.Many(scale=:Emitter), every=PSE.Dates.Hour(1),
            inputs=(:tick => PSE.One(id=:root, within=PSE.SceneScope(), application=:birth, var=:visits),),
            outputs_to=(PSE.OutputTo(PSE.Many(PSE.SceneScope(); scale=:Leaf); vars=(:signal,)),)),
    ))
end

end
