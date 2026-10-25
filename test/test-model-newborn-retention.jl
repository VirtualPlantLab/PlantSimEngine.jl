module NewbornRetentionReproducer

using Dates
using PlantSimEngine
using Test

export scenario, validate

PlantSimEngine.@process "newborn_retention_signal" verbose=false
PlantSimEngine.@process "newborn_retention_controller" verbose=false

struct Signal <: AbstractNewborn_Retention_SignalModel end
PlantSimEngine.inputs_(::Signal) = NamedTuple()
PlantSimEngine.outputs_(::Signal) = (value=0.0,)
function PlantSimEngine.run!(::Signal, status, environment, constants, context)
    status.value += 1.0
    return nothing
end

struct Controller <: AbstractNewborn_Retention_ControllerModel
    remove_at::Int
end
PlantSimEngine.inputs_(::Controller) = NamedTuple()
PlantSimEngine.outputs_(::Controller) = (iteration=0, called=0)
function PlantSimEngine.run!(model::Controller, status, environment, constants, context)
    status.iteration += 1
    runtime = runtime_model(context)
    if status.iteration == 1
        register_object!(runtime, Object(:newborn; scale=:Leaf, parent=:scene))
    elseif status.iteration == model.remove_at
        remove_object!(runtime, :newborn)
    end
    # Explicit current objects requests lifecycle preparation for the newborn
    # inside the same controller; no cached target or private runtime field.
    targets = run_call!(context, :signals;
        objects=object_ids(runtime; scale=:Leaf), publish=true)
    status.called = length(targets)
    return nothing
end

const START = DateTime(2026, 10, 24)

function scenario(; remove_at=0, steps=3)
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:existing; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(Controller(remove_at); name=:controller, on=One(id=:scene),
                calls=(:signals => Many(scale=:Leaf, within=Subtree(), application=:signal),),
                every=Hour(1)),
            ModelSpec(Signal(); name=:signal, on=Many(scale=:Leaf), every=Hour(1)),
        ),
        environment=[(date=START + Hour(i - 1), duration=Hour(1)) for i in 1:steps],
    )
end

function retention(mode)
    mode == :all && return :all
    mode == :request && return OutputRequest(Many(scale=:Leaf), :value;
        name=:leaf_value, application=:signal, policy=HoldLast(), clock=Hour(1))
    throw(ArgumentError("mode must be :all or :request"))
end

"""Assertions for accepted-state values, clocks, unique samples and removal history."""
function validate()
    @testset "newborn manual-call retained publication" begin
        for mode in (:all, :request), remove_at in (0, 3)
            model = scenario(; remove_at, steps=3)
            simulation = run!(model; steps=1, outputs=retention(mode))
            for _ in 2:3
                step!(simulation)
            end
            for (id, expected_steps) in ((:existing, [1, 2, 3]),
                    (:newborn, remove_at == 3 ? [1, 2] : [1, 2, 3]))
                rows = collect_outputs(simulation, id, :value; sink=nothing)
                @test getproperty.(rows, :timestep) == expected_steps
                @test getproperty.(rows, :datetime) ==
                    [START + Hour(i - 1) for i in expected_steps]
                @test getproperty.(rows, :value) == Float64.(1:length(expected_steps))
                @test length(unique(getproperty.(rows, :timestep))) == length(rows)
                @test outputs(simulation)[(:signal, ObjectId(id), :value)] ==
                    [(Float64(i), Float64(i)) for i in expected_steps]
            end
            @test (ObjectId(:newborn) in object_ids(model)) == (remove_at != 3)
            if mode == :request
                rows = collect_outputs(simulation, :leaf_value; sink=nothing)
                for id in (:existing, :newborn)
                    selected = filter(row -> row.object_id == id, rows)
                    expected_steps = id == :newborn && remove_at == 3 ? [1, 2] : [1, 2, 3]
                    @test getproperty.(selected, :timestep) == expected_steps
                    @test getproperty.(selected, :value) == Float64.(1:length(expected_steps))
                end
            end
        end
    end
    return (validated=true, package_root=pkgdir(PlantSimEngine),
        version=string(Base.pkgversion(PlantSimEngine)))
end

end # module

module PublicationChecks
using Dates, PlantSimEngine, Test
using ..NewbornRetentionReproducer: Signal, START, retention

PlantSimEngine.@process "retention_publication_check" verbose=false
struct PublicationController <: AbstractRetention_Publication_CheckModel
    pattern::Symbol
end
PlantSimEngine.outputs_(::PublicationController) = (iteration=0,)
function PlantSimEngine.run!(m::PublicationController, status, environment, constants, context)
    status.iteration += 1
    runtime = runtime_model(context)
    status.iteration == 1 && register_object!(runtime,
        Object(:newborn; scale=:Leaf, parent=:scene))
    ids = object_ids(runtime; scale=:Leaf)
    if m.pattern == :trial_then_next_step
        run_call!(context, :signals; objects=ids, publish=status.iteration > 1)
    elseif m.pattern == :repeat_accepted
        run_call!(context, :signals; objects=ids, publish=false)
        run_call!(context, :signals; objects=ids, publish=true)
        run_call!(context, :signals; objects=ids, publish=true)
    else
        run_call!(context, :signals; objects=ids, publish=true)
    end
    return nothing
end
function scenario(pattern; initially_empty=false)
    objects = [Object(:scene; scale=:Scene)]
    initially_empty || push!(objects, Object(:existing; scale=:Leaf, parent=:scene))
    return CompositeModel(objects...; applications=(
        ModelSpec(PublicationController(pattern); name=:controller, on=One(id=:scene),
            calls=(signals=Many(scale=:Leaf, within=Subtree(), application=:signal),),
            every=Hour(1)),
        ModelSpec(Signal(); name=:signal, on=Many(scale=:Leaf), every=Hour(1))),
        environment=[(date=START + Hour(i - 1), duration=Hour(1)) for i in 1:2])
end
function validate()
    @testset "Publication stays separate from stream initialization" begin
        for mode in (:all, :request)
            model = scenario(:trial_then_next_step)
            sim = run!(model; steps=1, outputs=retention(mode))
            for id in (:existing, :newborn)
                @test isempty(outputs(sim)[(:signal, ObjectId(id), :value)])
                @test isempty(collect_outputs(sim, id, :value; sink=nothing))
            end
            step!(sim)
            for id in (:existing, :newborn)
                @test outputs(sim)[(:signal, ObjectId(id), :value)] == [(2.0, 2.0)]
            end
            repeated = scenario(:repeat_accepted)
            sim = run!(repeated; steps=2, outputs=retention(mode))
            for id in (:existing, :newborn)
                @test outputs(sim)[(:signal, ObjectId(id), :value)] == [(1.0, 3.0), (2.0, 6.0)]
            end
            empty = scenario(:accepted; initially_empty=true)
            sim = run!(empty; steps=2, outputs=retention(mode))
            @test outputs(sim)[(:signal, ObjectId(:newborn), :value)] == [(1.0, 1.0), (2.0, 2.0)]
        end
        model = scenario(:repeat_accepted)
        sim = run!(model; steps=2, outputs=:none)
        @test isempty(outputs(sim))
        @test model_status(model, :newborn).value == 6.0
    end
end
end

@testset "Newborn retained manual calls" begin
    NewbornRetentionReproducer.validate()
    PublicationChecks.validate()
end
