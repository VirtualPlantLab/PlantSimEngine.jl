module NormalizedModelSpecChecks

using Dates, PlantMeteo, PlantSimEngine, Test
using PlantSimEngine.Diagnostics: object_address
const PSE = PlantSimEngine
PSE.@process "normalized_spec_declarations" verbose=false
PSE.@process "normalized_spec_snapshot" verbose=false
PSE.@process "normalized_spec_leaf" verbose=false
PSE.@process "normalized_spec_driver" verbose=false
PSE.@process "normalized_spec_creator" verbose=false
PSE.@process "normalized_spec_defaults" verbose=false

struct Declarations{D,C,F} <: AbstractNormalized_Spec_DeclarationsModel
    dependencies::D
    calls::C
    forbid_replay::F
end
function PSE.dep(model::Declarations)
    model.calls[] += 1
    model.forbid_replay[] && error("dependency declarations were replayed")
    return model.dependencies
end
struct TestWindow <: PlantMeteo.AbstractSamplingWindow end

@testset "one dependency snapshot and one normalized ModelSpec assembly" begin
    input = Input(One(Self(); process=:normalized_spec_leaf, var=:value))
    call = Call(One(Self(); process=:normalized_spec_leaf))
    initializer = Initializer(One(Subtree(); application=:leaf, scale=:Leaf))
    dependencies = (value=input, leaf=call, start=initializer)
    calls, forbidden = Ref(0), Ref(false)
    model = Declarations(dependencies, calls, forbidden)
    spec = ModelSpec(model; name="driver", on=Many(scale=:Controller),
        outputs_to=(OutputTo(Many(scale=:Leaf); vars=(:distributed,)),),
        environment=Environment(provider=:global), every=Hour(2),
        output_routing=(trace=:stream_only,), updates=Updates(:trace; after=:producer))
    @test calls[] == 1
    @test spec.model === model
    @test spec.name === :driver
    @test spec.inputs.value === input.selector
    @test spec.calls.leaf === call.selector
    @test spec.calls.start === initializer
    @test spec.input_origins === (value=:model_default,)
    @test spec.call_origins === (leaf=:model_default, start=:model_default)

    # Environment resolution has no authority to reconstruct already-authored
    # dependencies, replace model defaults, or change their origin.
    forbidden[] = true
    bindings = (T=(source=:air, reducer=MeanWeighted()),)
    updated = PSE._model_spec_with_environment_settings(spec;
        environment_bindings=bindings, environment_window=TestWindow)
    @test calls[] == 1
    @test updated.environment_bindings === bindings
    @test updated.environment_window isa TestWindow
    for name in fieldnames(typeof(spec))
        name in (:environment_bindings, :environment_window) && continue
        @test getfield(updated, name) === getfield(spec, name)
    end
    unchanged = PSE._model_spec_with_environment_settings(updated)
    @test unchanged === updated
    @test calls[] == 1
    @test_throws "Unsupported environment binding" PSE._model_spec_with_environment_settings(
        spec; environment_bindings=(T=17,))
    @test_throws "Unsupported environment sampling window" PSE._model_spec_with_environment_settings(
        spec; environment_window=3)
    @test calls[] == 1

    # Scenario overrides keep their existing validation and origin rules.
    forbidden[] = false
    explicit_input = One(application=:source, var=:value)
    explicit_call = OptionalOne(application=:replacement)
    overridden = ModelSpec(model; inputs=(value=explicit_input,), calls=(leaf=explicit_call,))
    @test calls[] == 2
    @test overridden.inputs.value === explicit_input
    @test overridden.calls.leaf === explicit_call
    @test overridden.calls.start === initializer
    @test overridden.input_origins === (value=:model_spec,)
    @test overridden.call_origins === (leaf=:model_spec, start=:model_default)
    @test_throws "`process=` in scenario" ModelSpec(model;
        inputs=(value=One(process=:normalized_spec_leaf),))
    @test_throws "`process=` in scenario" ModelSpec(model;
        calls=(leaf=One(process=:normalized_spec_leaf),))
    @test_throws "`Initializer` requires `One" Initializer(Many(scale=:Leaf))
end

struct Snapshot{C} <: AbstractNormalized_Spec_SnapshotModel
    calls::C
end
function PSE.dep(model::Snapshot)
    model.calls[] += 1
    id = Symbol(:leaf_, model.calls[])
    return (value=Input(One(id=id, var=:value)), leaf=Call(One(id=id)))
end

@testset "Input and Call defaults belong to the same declaration event" begin
    calls = Ref(0)
    first = ModelSpec(Snapshot(calls))
    @test calls[] == 1
    @test object_address(first.inputs.value).id == object_address(first.calls.leaf).id
    second = ModelSpec(Snapshot(calls))
    @test calls[] == 2
    @test object_address(second.inputs.value).id == object_address(second.calls.leaf).id
    @test object_address(first.inputs.value).id != object_address(second.inputs.value).id

    # A genuine author edit still uses the normal builder once, preserving
    # the existing normalized declarations and their supplied origin maps.
    renamed = PSE._replace_model_spec(first; name=:renamed)
    @test calls[] == 3
    @test renamed.name === :renamed
    @test renamed.inputs === first.inputs
    @test renamed.calls === first.calls
    @test renamed.input_origins === first.input_origins
    @test renamed.call_origins === first.call_origins
end

struct Leaf <: AbstractNormalized_Spec_LeafModel end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.environment_inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (value=1f0, calls=0)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.value += 2f0
    status.calls += 1
    return nothing
end

struct Driver{C,F} <: AbstractNormalized_Spec_DriverModel
    dependency_calls::C
    forbid_replay::F
end
function PSE.dep(model::Driver)
    model.dependency_calls[] += 1
    model.forbid_replay[] && error("dependency declarations were replayed")
    return (leaf=Call(One(Self(); process=:normalized_spec_leaf)),)
end
PSE.inputs_(::Driver) = NamedTuple()
PSE.outputs_(::Driver) = (seen=0f0, drivers=0)
PSE.environment_inputs_(::Driver) = (T=0f0,)
PSE.environment_hint(::Driver) = (bindings=(T=(source=:air,),),)
function PSE.run!(::Driver, status, environment, constants, context)
    status.seen = only(run_call!(context, :leaf; publish=true)).status.value + environment.T
    status.drivers += 1
    return nothing
end

@testset "public hinted execution preserves model-authored Call origin without dep replay" begin
    calls, forbidden = Ref(0), Ref(false)
    driver = ModelSpec(Driver(calls, forbidden); name=:driver, on=One(id=:leaf))
    @test calls[] == 1
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(driver,
        ModelSpec(Leaf(); name=:leaf, on=One(id=:leaf))),
        environment=(air=17f0, duration=Hour(1)))
    forbidden[] = true
    simulation = run!(model; outputs=:all)
    @test calls[] == 1
    resolved = simulation.compiled.applications_by_id[:driver].spec
    @test resolved.calls === driver.calls
    @test resolved.call_origins === driver.call_origins
    @test resolved.environment_bindings.T.source === :air
    @test model_status(model, :leaf).seen === 20f0
    @test model_status(model, :leaf).calls == 1
    @test model_status(model, :leaf).drivers == 1
    @test outputs(simulation)[(:leaf, ObjectId(:leaf), :value)] == [(1.0, 3f0)]
end

@testset "hint and explicit remapping/window retain their existing precedence" begin
    calls, forbidden = Ref(0), Ref(false)
    source = Driver(calls, forbidden)
    spec = ModelSpec(source; name=:driver, on=One(id=:leaf),
        environment=Environment(sources=(T=:explicit_air,)))
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(spec,),
        environment=(air=17f0, explicit_air=23f0, duration=Hour(1)))
    forbidden[] = true
    hint = (bindings=(T=(source=:air, reducer=MeanWeighted()),), window=TestWindow)
    resolved = PSE._model_spec_with_environment_hints(model, spec, :Leaf, hint)
    @test calls[] == 1
    @test resolved.environment_bindings.T.source === :explicit_air
    @test resolved.environment_window isa TestWindow
    @test resolved.calls === spec.calls
    @test resolved.call_origins === spec.call_origins

    forbidden[] = false
    explicit_window = PlantMeteo.RollingWindow(3.0)
    explicit = ModelSpec(source; environment_bindings=(T=(source=:chosen,),),
        environment_window=explicit_window)
    forbidden[] = true
    resolved = PSE._model_spec_with_environment_hints(model, explicit, :Leaf, hint)
    @test resolved.environment_bindings.T.source === :chosen
    @test resolved.environment_window === explicit_window
    @test calls[] == 2

    invalid = ModelSpec(Leaf(); environment=Environment(sources=(unknown=:air,)))
    @test_throws "unknown model-facing environment input" PSE._model_spec_with_environment_hints(
        model, invalid, :Leaf, nothing)
    errors = Any[]
    diagnostic = PSE._model_spec_with_environment_hints(model, invalid, :Leaf, nothing;
        on_error=error -> push!(errors, error))
    @test diagnostic === invalid
    @test length(errors) == 1
    @test occursin("unknown model-facing environment input", sprint(showerror, only(errors)))
end

struct Creator{C} <: AbstractNormalized_Spec_CreatorModel
    dependency_calls::C
end
function PSE.dep(model::Creator)
    model.dependency_calls[] += 1
    return (start=Initializer(One(Subtree(); scale=:Leaf, application=:leaf)),)
end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (created=false,)
PSE.environment_inputs_(::Creator) = (T=0f0,)
PSE.environment_hint(::Creator) = (bindings=(T=(source=:air,),),)
function PSE.run!(::Creator, status, environment, constants, context)
    status.created && return nothing
    object = register_object!(runtime_model(context), Object(:born; scale=:Leaf,
        parent=:scene, status=Status(value=3f0, calls=0)))
    run_initializer!(context, :start, object)
    status.created = true
    return nothing
end

@testset "environment rewrite preserves real newborn Initializer mode" begin
    calls = Ref(0)
    creator = ModelSpec(Creator(calls); name=:creator, on=One(id=:scene))
    model = CompositeModel(Object(:scene; scale=:Scene); applications=(creator,
        ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf))),
        environment=(air=17f0, duration=Hour(1)))
    simulation = run!(model; outputs=:all)
    resolved = simulation.compiled.applications_by_id[:creator].spec
    @test calls[] == 1
    @test resolved.calls.start === creator.calls.start
    @test resolved.calls.start isa Initializer
    @test resolved.call_origins === (start=:model_default,)
    @test model_status(model, :born).calls == 1
    @test model_status(model, :born).value === 5f0
    @test isempty(get(outputs(simulation), (:leaf, ObjectId(:born), :calls), []))
    continue!(simulation)
    @test calls[] == 1
    @test model_status(model, :born).calls == 2
    @test outputs(simulation)[(:leaf, ObjectId(:born), :calls)] == [(2.0, 2)]
end

struct FreshDefaults <: AbstractNormalized_Spec_DefaultsModel end
PSE.inputs_(::FreshDefaults) = (buffer=Default(Int[]),)
PSE.outputs_(::FreshDefaults) = (count=0,)
PSE.environment_inputs_(::FreshDefaults) = (T=0f0,)
PSE.environment_hint(::FreshDefaults) = (bindings=(T=(source=:air,),),)
function PSE.run!(::FreshDefaults, status, environment, constants, context)
    push!(status.buffer, Int(context.time))
    status.count += 1
    return nothing
end

@testset "normal mutable default values remain fresh for initial and newborn objects" begin
    model = CompositeModel(Object(:a; scale=:Leaf), Object(:b; scale=:Leaf);
        applications=(ModelSpec(FreshDefaults(); name=:defaults, on=Many(scale=:Leaf)),),
        environment=(air=17f0, duration=Hour(1)))
    simulation = run!(model)
    a, b = model_status(model, :a), model_status(model, :b)
    @test a.buffer == b.buffer == [1]
    @test a.buffer !== b.buffer
    register_object!(model, Object(:c; scale=:Leaf))
    continue!(simulation)
    c = model_status(model, :c)
    @test a.buffer == b.buffer == [1, 2]
    @test c.buffer == [2]
    @test c.buffer !== a.buffer && c.buffer !== b.buffer
    @test a.count == b.count == 2
    @test c.count == 1
end

end
