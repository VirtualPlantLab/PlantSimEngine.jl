module SourceCallEvaluationChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
PSE.@process "source_evaluation_leaf_probe" verbose=false
PSE.@process "source_evaluation_middle_probe" verbose=false
PSE.@process "source_evaluation_owner_probe" verbose=false
PSE.@process "source_evaluation_membership_probe" verbose=false

struct Leaf <: AbstractSource_Evaluation_Leaf_ProbeModel end
PSE.inputs_(::Leaf) = (driver=Default(0.0),)
PSE.outputs_(::Leaf) = (seen=0.0, leaf_calls=0)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.leaf_calls += 1
    status.seen = status.driver
    return nothing
end

struct Middle <: AbstractSource_Evaluation_Middle_ProbeModel end
PSE.outputs_(::Middle) = (middle_seen=0.0, middle_calls=0)
function PSE.run!(::Middle, status, environment, constants, context)
    status.middle_calls += 1
    child = only(call_targets(context, :leaf))
    child.status.driver = 2.0
    run_call!(child; publish=false)
    child.status.driver = 7.0
    run_call!(context, :leaf; publish=true)
    status.middle_seen = child.status.seen
    return nothing
end

struct Owner{C} <: AbstractSource_Evaluation_Owner_ProbeModel
    mode::Symbol
    capture::C
end
PSE.outputs_(::Owner) = (stale_rejected=false, accepted_seen=0.0, owner_calls=0)
function PSE.run!(model::Owner, status, environment, constants, context)
    status.owner_calls += 1
    model.capture[] = context
    if model.mode === :clock
        return nothing
    elseif model.mode === :nested
        evaluated = evaluate_call!(context, :middle)
        status.accepted_seen = only(call_targets(evaluated)).status.middle_seen
        accept_call!(evaluated)
        return nothing
    end
    child = only(call_targets(context, :leaf))
    child.status.driver = 2.0
    if model.mode === :individual
        pending = evaluate_call!(child)
        run_call!(child; publish=false)
    else
        pending = evaluate_call!(context, :leaf)
        run_call!(context, :leaf; publish=false)
    end
    try
        accept_call!(pending)
    catch error
        status.stale_rejected = error isa ArgumentError
    end
    child.status.driver = 7.0
    accepted = evaluate_call!(child)
    accept_call!(accepted)
    status.accepted_seen = child.status.seen
    return nothing
end

function scene(mode; S=Float64)
    capture = Ref{Any}()
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:middle; scale=:Plant, parent=:owner),
        Object(:leaf; scale=:Leaf, parent=:middle); applications=(
            ModelSpec(Owner(mode, capture); name=:owner, on=One(id=:owner), calls=(
                leaf=One(id=:leaf, within=Subtree(), application=:leaf),
                middle=One(id=:middle, within=Subtree(), application=:middle),)),
            ModelSpec(Middle(); name=:middle, on=One(id=:middle),
                calls=(leaf=One(id=:leaf, within=Subtree(), application=:leaf),)),
            ModelSpec(Leaf(); name=:leaf, on=One(id=:leaf)),
        ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => S))
    return (; model, capture)
end

function generated_executor(model, name)
    source = PSE.Authoring.compiled_model_source(model; function_name=name)
    # These probe models belong to an in-memory test module, rather than an
    # importable package. Bind that existing module in the generated namespace.
    source = replace(source, "import SourceCallEvaluationChecks\n" =>
        "import Main.SourceCallEvaluationChecks\n")
    generated_module = Module(gensym(:CallEvaluationSource))
    path = tempname() * ".jl"
    write(path, source)
    Base.include(generated_module, path)
    return Core.eval(generated_module, name), source
end

@testset "generated manual executions invalidate evaluations and preserve acceptance" begin
    for mode in (:individual, :bulk, :nested), S in (Float32, Float64)
        generated_case = scene(mode; S)
        normal_case = scene(mode; S)
        generated_run, source = generated_executor(generated_case.model, :call_evaluation_source!)
        @test occursin("PlantSimEngine._compiled_source_run_call!", source)
        generated = Base.invokelatest(generated_run, generated_case.model; outputs=:all)
        normal = run!(normal_case.model; outputs=:all)
        for simulation in (generated, normal)
            state = final_state(simulation, :owner)
            @test state.accepted_seen === S(7)
            @test state.stale_rejected == (mode !== :nested)
            @test final_state(simulation, :leaf).leaf_calls == (mode === :nested ? 2 : 3)
            @test outputs(simulation)[(:leaf, ObjectId(:leaf), :seen)] == [(1.0, S(7))]
        end
        @test isequal(final_state(generated, Many()), final_state(normal, Many()))
        @test isequal(collect_outputs(generated; sink=nothing), collect_outputs(normal; sink=nothing))
    end
end

@testset "generated step advancement expires a pending ordinary evaluation" begin
    fixture = scene(:clock)
    generated_run, _ = generated_executor(fixture.model, :call_evaluation_clock_source!)
    simulation = Base.invokelatest(generated_run, fixture.model; outputs=:all)
    pending = evaluate_call!(fixture.capture[], :leaf)
    @test final_state(simulation, :leaf).leaf_calls == 1
    Base.invokelatest(generated_run, simulation; steps=1)
    @test_throws ArgumentError accept_call!(pending)
    @test isempty(outputs(simulation)[(:leaf, ObjectId(:leaf), :seen)])
end

struct MembershipOwner <: AbstractSource_Evaluation_Membership_ProbeModel end
PSE.outputs_(::MembershipOwner) = (iteration=0,)
function PSE.run!(::MembershipOwner, status, environment, constants, context)
    status.iteration += 1
    run_call!(context, :leaves; publish=true)
    if status.iteration == 1
        register_object!(runtime_model(context), Object(:newborn; scale=:Leaf, parent=:owner))
    end
    return nothing
end

@testset "generated accepted empty calls preserve newborn request membership" begin
    start = DateTime(2026, 10, 27)
    model = CompositeModel(Object(:owner; scale=:Scene); applications=(
        ModelSpec(MembershipOwner(); name=:owner, on=One(id=:owner),
            calls=(leaves=Many(scale=:Leaf, within=Subtree(), application=:leaf),)),
        ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
    ), environment=[(date=start + Hour(i - 1), duration=Hour(1)) for i in 1:2])
    generated_run, _ = generated_executor(model, :call_evaluation_membership_source!)
    request = OutputRequest(Many(scale=:Leaf), :seen; name=:leaf_seen,
        application=:leaf, policy=HoldLast(), clock=Hour(1))
    simulation = Base.invokelatest(generated_run, model; steps=1, outputs=request)
    @test isempty(collect_outputs(simulation, :leaf_seen; sink=nothing))
    Base.invokelatest(generated_run, simulation; steps=1)
    rows = collect_outputs(simulation, :leaf_seen; sink=nothing)
    @test length(rows) == 1
    @test only(rows).object_id == :newborn
    @test only(rows).timestep == 2
    @test only(rows).value == 0.0
end

end # module SourceCallEvaluationChecks
