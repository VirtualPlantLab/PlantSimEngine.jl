module AuthoredCallPlanChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "authored_call_leaf" verbose=false
PSE.@process "authored_call_driver" verbose=false
PSE.@process "authored_call_creator" verbose=false
PSE.@process "authored_call_broken" verbose=false

struct Leaf <: AbstractAuthored_Call_LeafModel end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (value=0f0, calls=0)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.value += 2f0
    status.calls += 1
    return nothing
end

struct Driver{D} <: AbstractAuthored_Call_DriverModel
    dependency_calls::D
end
PSE.inputs_(::Driver) = NamedTuple()
PSE.outputs_(::Driver) = (seen=0f0, drivers=0)
function PSE.dep(model::Driver)
    model.dependency_calls[] += 1
    return (leaf=Call(One(Scope(ObjectId(:future_root)); scale=:Leaf, application=:leaf)),)
end
function PSE.run!(::Driver, status, environment, constants, context)
    status.drivers += 1
    status.seen = only(run_call!(context, :leaf; publish=true)).status.value
    return nothing
end

function scene(; every=Hour(1), environment=(duration=Hour(1),), with_leaf=false)
    dependencies = Ref(0)
    driver = ModelSpec(Driver(dependencies); name=:driver, on=One(id=:scene), every)
    leaf = ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf), every)
    normalized_count = dependencies[]
    @test PSE.model_calls(driver).leaf isa One
    @test dependencies[] == normalized_count
    model = CompositeModel(Object(:scene; scale=:Scene,
        status=Status(seen=0f0, drivers=0)); applications=(driver, leaf), environment)
    @test dependencies[] == normalized_count
    if with_leaf
        register_leaf!(model)
    end
    return (; model, dependencies, normalized_count, driver)
end

function register_leaf!(model)
    register_object!(model, Object(:future_root; scale=:Plant, parent=:scene))
    return register_object!(model, Object(:leaf; scale=:Leaf, parent=:future_root,
        status=Status(value=3f0, calls=0)))
end

@testset "constructor prepares normalized Call routes but resolves symbolic Scope at run" begin
    data = scene()
    preparation = data.model.scenario_plan_cache
    recipe = preparation.authored[1]
    authored = only(recipe.call_plans)
    @test authored isa PSE.CompiledModelCallPlan
    @test authored.application_id === :driver
    @test PSE._compiled_call_name(authored) === :leaf
    @test PSE._compiled_call_mode(authored) === :manual
    @test authored.matcher.scope isa Scope
    @test authored.potential_callee_application_ids == (:leaf,)
    @test isempty(preparation.authored[2].call_plans)
    @test isnothing(preparation.failure)
    applications = PSE._compile_model_applications(data.model, Tuple(data.model.applications),
        PSE._model_timeline(data.model))
    @test applications[1].call_plans === recipe.call_plans
    @test_throws "No instance or object ID" PSE._compile_model_call_plans(data.model, applications)
    @test data.dependencies[] == data.normalized_count
    @test isnothing(preparation.failure) # unresolved live scope is not an authoring failure

    register_leaf!(data.model)
    simulation = run!(data.model; steps=2, outputs=:all)
    resolved = only(simulation.compiled.scenario_plan.call_plans)
    @test resolved.matcher.scope isa PSE.CompiledNamedScope
    @test resolved.matcher.scope.root_id === ObjectId(:future_root)
    runtime_plans = simulation.compiled.scenario_plan.call_plans_by_application
    @test only(runtime_plans[:driver]) === resolved
    binding = only(simulation.compiled.call_bindings)
    @test binding.plan === resolved
    @test PSE._current_call_binding_for_application(simulation.compiled,
        simulation.compiled.applications_by_id[:driver], binding) === binding

    # Same type, different resolved scope: only the actual runtime declaration
    # may own a binding, even when the current target set happens to overlap.
    with_field(value, name, replacement) = typeof(value)(ntuple(
        index -> fieldnames(typeof(value))[index] === name ? replacement : getfield(value, index),
        fieldcount(typeof(value)))...)
    foreign_scope = with_field(resolved.matcher.scope, :root_id, ObjectId(:scene))
    foreign_matcher = with_field(resolved.matcher, :scope, foreign_scope)
    foreign_plan = with_field(resolved, :matcher, foreign_matcher)
    foreign_binding = PSE.CompiledModelCallBinding(foreign_plan, binding.consumer_id,
        binding.callee_object_ids, binding.callee_application_ids)
    @test typeof(foreign_binding) === typeof(binding)
    @test_throws "outside its prepared application declaration" PSE._index_model_call_bindings(
        [foreign_binding], runtime_plans, keytype(data.model.registry.objects))
    @test resolved.matcher.scope.root_id === ObjectId(:future_root)
    @test only(recipe.call_plans).matcher.scope isa Scope
    @test model_status(data.model, :leaf).value === 7f0
    @test model_status(data.model, :leaf).calls == 2
    @test model_status(data.model, :scene).seen === 7f0
    @test outputs(simulation)[(:leaf, ObjectId(:leaf), :value)] == [(1.0, 5f0), (2.0, 7f0)]
    PSE._compile_model_call_plans(data.model, simulation.compiled.applications)
    @test data.dependencies[] == data.normalized_count

    # A compiler call with another explicit spec set must use that set's
    # prepared declarations, never the model's default preparation cache.
    alternate_driver = ModelSpec(Driver(data.dependencies); name=:alternate_driver,
        on=One(id=:scene), calls=(leaf=One(Scope(ObjectId(:future_root));
            scale=:Leaf, application=:alternate_leaf),))
    alternate_leaf = ModelSpec(Leaf(); name=:alternate_leaf, on=Many(scale=:Leaf))
    before_compile = data.dependencies[]
    alternate = PSE.compile_composite_model(data.model, (alternate_driver, alternate_leaf))
    @test only(alternate.scenario_plan.call_plans).application_id === :alternate_driver
    @test only(alternate.scenario_plan.call_plans).potential_callee_application_ids == (:alternate_leaf,)
    @test data.dependencies[] == before_compile
    @test data.model.scenario_plan_cache === preparation
end

@testset "cadence and environment stay runtime while Call declarations remain shared" begin
    data = scene(; every=Hour(2), with_leaf=true)
    preparation = data.model.scenario_plan_cache
    authored = preparation.authored[1].call_plans
    original = run!(data.model; steps=0)
    @test original.compiled.applications_by_id[:driver].clock.dt == 2.0
    data.model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(data.model)
    restarted = run!(data.model; steps=2)
    @test restarted.compiled.applications_by_id[:driver].clock.dt == 1.0
    @test original.compiled.applications_by_id[:driver].clock.dt == 2.0
    @test restarted.compiled.applications_by_id[:driver].call_plans === authored
    @test model_status(data.model, :leaf).calls == 2
    @test data.dependencies[] == data.normalized_count
end

struct Creator{D} <: AbstractAuthored_Call_CreatorModel
    dependency_calls::D
end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (created=false,)
function PSE.dep(model::Creator)
    model.dependency_calls[] += 1
    return (start=Initializer(One(Subtree(); scale=:Leaf, application=:leaf)),)
end
function PSE.run!(::Creator, status, environment, constants, context)
    status.created && return nothing
    object = register_object!(runtime_model(context), Object(:born; scale=:Leaf,
        parent=:scene, status=Status(value=3f0, calls=0)))
    run_initializer!(context, :start, object)
    status.created = true
    return nothing
end

@testset "default Initializer mode retains scheduled newborn and publication semantics" begin
    dependencies = Ref(0)
    creator = ModelSpec(Creator(dependencies); name=:creator, on=One(id=:scene))
    normalized_count = dependencies[]
    model = CompositeModel(Object(:scene; scale=:Scene); applications=(creator,
        ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf))))
    @test PSE._compiled_call_mode(only(model.scenario_plan_cache.authored[1].call_plans)) === :initializer
    @test dependencies[] == normalized_count
    simulation = run!(model; outputs=:all)
    @test model_status(model, :born).calls == 1
    @test model_status(model, :born).value === 5f0
    @test isempty(get(outputs(simulation), (:leaf, ObjectId(:born), :calls), []))
    continue!(simulation)
    @test model_status(model, :born).calls == 2
    @test outputs(simulation)[(:leaf, ObjectId(:born), :calls)] == [(2.0, 2)]
    @test dependencies[] == normalized_count
end

const failed_declarations = Ref(0)
struct Broken <: AbstractAuthored_Call_BrokenModel end
function PSE.outputs_(::Broken)
    failed_declarations[] += 1
    error("intentional authored output failure")
end

@testset "partial reports retain later Call declarations and original application slots" begin
    failed_declarations[] = 0
    dependencies = Ref(0)
    driver = ModelSpec(Driver(dependencies); name=:driver, on=One(id=:scene))
    model = CompositeModel(Object(:scene; scale=:Scene, status=Status(seen=0f0, drivers=0)),
        Object(:future_root; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:future_root, status=Status(value=3f0, calls=0));
        applications=(ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
            ModelSpec(Broken(); name=:broken, on=One(id=:scene)), driver))
    @test model.scenario_plan_cache.failure.application_id === :broken
    @test length(model.scenario_plan_cache.authored[3].call_plans) == 1
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:leaf, :driver]
    @test [application.slot for application in report.applications] == [1, 3]
    @test length(report.call_bindings) == 1
    binding = only(report.call_bindings)
    @test binding.application_id === :driver
    @test binding.callee_object_ids == [ObjectId(:leaf)]
    @test binding.callee_application_ids == [:leaf]
    @test failed_declarations[] == 1
end

@testset "partial live membership filters only missing callee applications" begin
    dependencies = Ref(0)
    driver = ModelSpec(Driver(dependencies); name=:driver, on=One(id=:scene))
    model = CompositeModel(Object(:scene; scale=:Scene, status=Status(seen=0f0, drivers=0)),
        Object(:future_root; scale=:Plant, parent=:scene);
        applications=(ModelSpec(Leaf(); name=:leaf, on=One(id=:missing)), driver))
    preparation = model.scenario_plan_cache
    @test isnothing(preparation.failure)
    @test only(preparation.authored[2].call_plans).potential_callee_application_ids == (:leaf,)
    # This is the same subset resolution used by the read-only graph report.
    applications = PSE._resolve_application_recipes(model,
        (preparation.authored[2],), PSE._model_timeline(model))
    @test isempty(only(PSE._compile_model_call_plans(model, applications)).potential_callee_application_ids)
    @test only(preparation.authored[2].call_plans).potential_callee_application_ids == (:leaf,)
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:driver]
    @test !isempty(report.diagnostics)
end

end
