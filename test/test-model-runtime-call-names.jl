module RuntimeCallNameChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "runtime_name_owner" verbose=false
PSE.@process "runtime_name_target" verbose=false
PSE.@process "runtime_name_creator" verbose=false

struct TargetA <: AbstractRuntime_Name_TargetModel end
struct TargetB <: AbstractRuntime_Name_TargetModel end
PSE.inputs_(::Union{TargetA,TargetB}) = NamedTuple()
PSE.outputs_(::TargetA) = (value=0f0, visits=0)
PSE.outputs_(::TargetB) = (value=0.0, visits=0, flag=false)
function PSE.run!(::TargetA, status, environment, constants, context)
    status.value += 2f0
    status.visits += 1
    return nothing
end
function PSE.run!(::TargetB, status, environment, constants, context)
    status.value += 7.0
    status.visits += 1
    status.flag = true
    return nothing
end

struct CaptureOwner{C} <: AbstractRuntime_Name_OwnerModel
    capture::C
end
PSE.outputs_(::CaptureOwner) = (visits=0,)
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

@noinline function cli_name(args::Vector{String})
    length(args) == 1 || throw(ArgumentError("Expected exactly one call name, got $(length(args))."))
    return Symbol(args[1])
end
cli_targets(context, args) = call_targets(context, cli_name(args))
cli_model(context, args) = call_model(context, cli_name(args))
cli_run(context, args; publish=false, objects=nothing) =
    run_call!(context, cli_name(args); publish, objects)
@inline literal_model(context::C) where {C} = call_model(context, :a)
function literal_model_allocations(context::C) where {C}
    literal_model(context)
    return @allocated literal_model(context)
end
function runtime_lookup_allocations(context::C, args) where {C}
    cli_targets(context, args)
    return @allocated cli_targets(context, args)
end

function manual_fixture()
    capture = Ref{Any}(nothing)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:first; scale=:LeafA, parent=:owner),
        Object(:second; scale=:LeafB, parent=:owner);
        applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
                calls=(
                    a=One(id=:first, within=SceneScope(), application=:target_a),
                    b=Many(id=:second, within=SceneScope(), application=:target_b),
                    empty=Many(id=:absent, within=SceneScope(), application=:target_a),
                )),
            ModelSpec(TargetA(); name=:target_a, on=Many(scale=:LeafA)),
            ModelSpec(TargetB(); name=:target_b, on=Many(scale=:LeafB)),
        ))
    return (; model, capture)
end

@testset "runtime Symbol calls keep finite heterogeneous target branches" begin
    @test_throws ArgumentError cli_name(String[])
    @test_throws ArgumentError cli_name(["a", "b"])
    fixture = manual_fixture()
    simulation = run!(fixture.model; outputs=:all)
    context = fixture.capture[]
    a_args, b_args = ["a"], ["b"]
    a = cli_targets(context, a_args)
    b = cli_targets(context, b_args)
    @test a === call_targets(context, :a)
    @test b === call_targets(context, :b)
    @test length(a) == length(b) == 1
    @test cli_model(context, a_args) isa TargetA
    @test cli_model(context, b_args) isa TargetB
    @test typeof(only(a)) !== typeof(only(b))
    @test cli_run(context, a_args; publish=true) === a
    @test cli_run(context, b_args; publish=true) === b
    @test model_status(fixture.model, :first).value === 2f0
    @test model_status(fixture.model, :second).value === 7.0
    @test model_status(fixture.model, :second).flag
    @test cli_run(context, b_args; publish=false) === b
    @test model_status(fixture.model, :second).value === 14.0
    @test outputs(simulation)[(:target_b, ObjectId(:second), :value)] == [(1.0, 7.0)]
    @test isempty(cli_run(context, ["empty"]; publish=true))
    @test_throws ArgumentError cli_model(context, ["empty"])
    @test_throws ErrorException cli_targets(context, ["missing"])
    @test_throws ErrorException cli_model(context, ["missing"])
    @test_throws ErrorException cli_run(context, ["missing"])
    @test_throws ErrorException cli_run(context, a_args; objects=:second)
    identity_error = try
        call_targets(context, cli_name(["missing"]); objects=:unregistered)
        nothing
    catch error
        error
    end
    @test identity_error isa ErrorException
    @test occursin("No model object", sprint(showerror, identity_error))
    previous_permission = context.publication_allowed
    permission_error = try
        context.publication_allowed = false
        run_initializer!(context, cli_name(["missing"]), :unregistered)
        nothing
    catch error
        error
    finally
        context.publication_allowed = previous_permission
    end
    @test permission_error isa ErrorException
    @test occursin("non-publishing hard call", sprint(showerror, permission_error))
    @test (@inferred literal_model(context)) isa TargetA
    @test literal_model_allocations(context) == 0
    @test runtime_lookup_allocations(context, a_args) == 0
    @test runtime_lookup_allocations(context, b_args) == 0
end

struct DynamicInitializerCreator{C} <: AbstractRuntime_Name_CreatorModel
    names::Vector{String}
    capture::C
end
PSE.outputs_(::DynamicInitializerCreator) = (
    observed_a=0f0, observed_b=0.0, created=false,
    manual_guard=false, unknown_guard=false, duplicate_guard=false,
)
function PSE.run!(model::DynamicInitializerCreator, status, environment, constants, context)
    status.created && return nothing
    status.created = true
    model.capture[] = context
    a = register_object!(runtime_model(context),
        Object(:born_a; scale=:LeafA, parent=:owner,
            status=Status(value=0f0, visits=0)))
    b = register_object!(runtime_model(context),
        Object(:born_b; scale=:LeafB, parent=:owner,
            status=Status(value=0.0, visits=0, flag=false)))
    status.manual_guard = try
        call_targets(context, cli_name(model.names[1:1]))
        false
    catch error
        error isa ArgumentError
    end
    status.unknown_guard = try
        run_initializer!(context, cli_name(["missing"]), a)
        false
    catch error
        error isa ErrorException
    end
    first_status = run_initializer!(context, cli_name(model.names[1:1]), a)
    status.duplicate_guard = try
        run_initializer!(context, cli_name(model.names[1:1]), a)
        false
    catch error
        error isa ErrorException
    end
    second_status = run_initializer!(context, cli_name(model.names[2:2]), b)
    status.observed_a = first_status.value
    status.observed_b = second_status.value
    return nothing
end

function initializer_fixture()
    capture = Ref{Any}(nothing)
    model = CompositeModel(Object(:owner; scale=:Scene);
        applications=(
            ModelSpec(DynamicInitializerCreator(["init_a", "init_b"], capture);
                name=:creator, on=One(id=:owner),
                calls=(
                    init_a=Initializer(One(scale=:LeafA, within=SceneScope(), application=:target_a)),
                    init_b=Initializer(One(scale=:LeafB, within=SceneScope(), application=:target_b)),
                )),
            ModelSpec(TargetA(); name=:target_a, on=Many(scale=:LeafA)),
            ModelSpec(TargetB(); name=:target_b, on=Many(scale=:LeafB)),
        ))
    return (; model, capture)
end

@testset "runtime Symbol initializers preserve one-shot mode and publication" begin
    fixture = initializer_fixture()
    model, capture = fixture.model, fixture.capture
    simulation = run!(model; outputs=:all)
    creator = model_status(model, :owner)
    @test creator.manual_guard
    @test creator.unknown_guard
    @test creator.duplicate_guard
    @test creator.observed_a === 2f0
    @test creator.observed_b === 7.0
    @test model_status(model, :born_a).value === 2f0
    @test model_status(model, :born_b).value === 7.0
    @test model_status(model, :born_a).visits == 1
    @test model_status(model, :born_b).visits == 1
    @test isempty(get(outputs(simulation), (:target_a, ObjectId(:born_a), :value), []))
    @test isempty(get(outputs(simulation), (:target_b, ObjectId(:born_b), :value), []))
    continue!(simulation)
    @test model_status(model, :born_a).value === 4f0
    @test model_status(model, :born_b).value === 14.0
    @test model_status(model, :born_a).visits == 2
    @test model_status(model, :born_b).visits == 2
    @test outputs(simulation)[(:target_a, ObjectId(:born_a), :value)] == [(2.0, 4f0)]
    @test outputs(simulation)[(:target_b, ObjectId(:born_b), :value)] == [(2.0, 14.0)]
    @test_throws ArgumentError cli_targets(capture[], ["init_a"])
    @test_throws ArgumentError cli_model(capture[], ["init_b"])
    @test_throws ArgumentError cli_run(capture[], ["init_a"])
end

@testset "readable source preserves runtime-named newborn initializers" begin
    @test PSE._compiled_source_module_path(@__MODULE__) == "Main.RuntimeCallNameChecks"
    @test PSE._compiled_source_module_path(PSE) == "PlantSimEngine"
    fixture = initializer_fixture()
    source = PSE.Authoring.compiled_model_source(fixture.model;
        function_name=:runtime_named_initializers!)
    @test occursin("_compiled_source_run_initializer!", source)
    mktempdir() do directory
        path = joinpath(directory, "RuntimeNamedInitializers.jl")
        write(path, source)
        generated_module = Module(gensym(:RuntimeNamedInitializers))
        Base.include(generated_module, path)
        generated_run = getfield(generated_module, :runtime_named_initializers!)
        generated = Base.invokelatest(generated_run, fixture.model; steps=1, outputs=:all)
        @test model_status(runtime_model(generated), :born_a).value === 2f0
        @test model_status(runtime_model(generated), :born_b).value === 7.0
        @test isempty(get(outputs(generated), (:target_a, ObjectId(:born_a), :value), []))
        @test isempty(get(outputs(generated), (:target_b, ObjectId(:born_b), :value), []))
        Base.invokelatest(generated_run, generated; steps=1)
        ordinary = run!(initializer_fixture().model; steps=2, outputs=:all)
        @test isequal(collect_outputs(generated; sink=nothing),
            collect_outputs(ordinary; sink=nothing))
        @test model_status(runtime_model(generated), :born_a).value === 4f0
        @test model_status(runtime_model(generated), :born_b).value === 14.0
    end
end

end
