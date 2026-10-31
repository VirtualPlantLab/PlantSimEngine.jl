module PlannerBoundaryChecks

using Dates, Random, Test, PlantSimEngine
const PSE = PlantSimEngine
const Boundaries = Main.PlannerBoundaries

export planner_width_fixture, planner_width_checks, planner_growth_checks,
    planner_pb_checks, planner_xp_checks

PSE.@process "planner_boundary_probe" verbose=false
PSE.@process "planner_boundary_creator" verbose=false

struct PlannerProbe{I,T,R} <: AbstractPlanner_Boundary_ProbeModel
    coefficient::T
    rng::R
end
PSE.inputs_(::PlannerProbe{I,T}) where {I,T} = (x=PSE.Required(T),)
PSE.outputs_(::PlannerProbe{I,T}) where {I,T} = (value=zero(T), visits=0)
function PSE.run!(model::PlannerProbe, status, environment, constants, context)
    status.visits += 1
    status.value = model.coefficient * status.x + rand(model.rng, typeof(status.x))
    return nothing
end

struct PlannerCreator{T} <: AbstractPlanner_Boundary_CreatorModel
    limit::Int
end
PSE.inputs_(::PlannerCreator) = NamedTuple()
PSE.outputs_(::PlannerCreator) = (births=0,)
function PSE.run!(model::PlannerCreator{T}, status, environment, constants, context) where {T}
    status.births >= model.limit && return nothing
    status.births += 1
    id = 100 + status.births
    PSE.register_object!(PSE.runtime_model(context), PSE.Object(id;
        parent=0, kind=:planner_unit, status=(x=T(id),)))
    return nothing
end

"""Fixed organ layout with a widening authored tuple of concrete model types."""
function planner_width_fixture(; nmodels=4, nobjects=2, T=Float32, growth=false)
    applications = Any[]
    growth && push!(applications, PSE.ModelSpec(PlannerCreator{T}(2);
        name=:creator, on=PSE.One(id=0), every=Hour(1)))
    for index in 1:nmodels
        model = PlannerProbe{index,T,MersenneTwister}(T(index), MersenneTwister(index))
        push!(applications, PSE.ModelSpec(model; name=Symbol(:planner_, index),
            on=PSE.Many(kind=:planner_unit), every=Hour(1),
            output_routing=(value=:stream_only, visits=:stream_only)))
    end
    organs = PSE.Object[PSE.Object(index; parent=0, kind=:planner_unit,
        status=(x=T(index),)) for index in 1:nobjects]
    return PSE.CompositeModel(PSE.Object(0), organs...;
        applications=Tuple(applications), environment=(duration=Hour(1),))
end

Base.@nospecializeinfer @noinline function _prepare(model; enabled=false,
    bounded=false, outputs=:all)
    @nospecialize model
    if bounded
        isdefined(Main, :BoundedPreparation) || error("Load BoundedPreparation for the bounded anchor")
        Base.invokelatest(getfield(Main, :BoundedPreparation).enable_bounded_preparation!, model)
    end
    enabled && Base.invokelatest(Boundaries.enable_planner_boundaries!, model)
    return Base.invokelatest(PSE.run!, model; steps=0, outputs)
end

Base.@nospecializeinfer @noinline function _rng_snapshot(model)
    @nospecialize model
    rows = Any[]
    for spec in model.applications
        process_model = spec.model
        for name in (:rng, :random_generator)
            hasproperty(process_model, name) || continue
            rng = getproperty(process_model, name)
            rng isa Random.AbstractRNG || continue
            push!(rows, (application=spec.name, field=name,
                next_draws=rand(copy(rng), UInt64, 4)))
        end
    end
    return rows
end

Base.@nospecializeinfer @noinline function _snapshot(simulation, kind)
    @nospecialize simulation
    if kind === :xp
        scientific = Base.invokelatest(getfield(Main, :NativeXPDriver).xp_portable_snapshot,
            simulation)
    else
        canonical = Dict{PSE.ObjectId,Any}()
        for object in PSE.model_objects(simulation.model)
            status = PSE.model_status(simulation.model, object.id)
            canonical[object.id] = status === nothing ? nothing : deepcopy(NamedTuple(status))
        end
        private = Dict(key => deepcopy(NamedTuple(view.status))
            for (key, view) in simulation.compiled.status_views_by_target)
        histories = Dict(key => deepcopy(collect(stream))
            for (key, stream) in pairs(PSE.outputs(simulation)))
        scientific = (step=PSE.current_step(simulation), canonical, private, histories)
    end
    topology = Dict(object.id => (parent=object.parent, kind=object.kind,
        scale=object.scale, geometry=PSE.geometry(object))
        for object in PSE.model_objects(simulation.model))
    return (; scientific, topology, model_rngs=_rng_snapshot(simulation.model))
end

Base.@nospecializeinfer @noinline function _identities(model)
    @nospecialize model
    statuses = Dict{PSE.ObjectId,Any}()
    cells = Dict{Tuple{PSE.ObjectId,Symbol},Any}()
    for object in PSE.model_objects(model)
        status = PSE.model_status(model, object.id)
        status === nothing && continue
        statuses[object.id] = status
        for name in propertynames(status)
            cells[(object.id, name)] = PSE.refvalue(status, name)
        end
    end
    return (; statuses, cells)
end

function _identity_transitions(left_before, right_before, left_after, right_after)
    @test Set(keys(left_after.statuses)) == Set(keys(right_after.statuses))
    @test Set(keys(left_after.cells)) == Set(keys(right_after.cells))
    for id in intersect(Set(keys(left_before.statuses)), Set(keys(left_after.statuses)))
        @test (left_after.statuses[id] === left_before.statuses[id]) ===
            (right_after.statuses[id] === right_before.statuses[id])
    end
    for key in intersect(Set(keys(left_before.cells)), Set(keys(left_after.cells)))
        @test (left_after.cells[key] === left_before.cells[key]) ===
            (right_after.cells[key] === right_before.cells[key])
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _scientific_types(simulation)
    @nospecialize simulation
    types = Dict{Any,Any}()
    for ((application_id, object_id), view) in simulation.compiled.status_views_by_target
        application = simulation.compiled.applications_by_id[application_id]
        model = PSE._application_model(application, object_id)
        bindings = get(simulation.compiled.input_bindings_by_target,
            (application_id, object_id), ())
        types[(application_id, object_id)] = (model=typeof(model),
            canonical=typeof(view.canonical_status), local_status=typeof(view.status),
            carriers=Type[typeof(binding.carrier) for binding in bindings])
    end
    return types
end

Base.@nospecializeinfer @noinline function _compare_models(left, right;
    kind=:synthetic, steps=2, outputs=:all, bounded=false)
    @nospecialize left right
    state = Dict{Symbol,Any}()
    state[:reference] = Base.invokelatest(_prepare, left; bounded, outputs)
    state[:candidate] = Base.invokelatest(_prepare, right; enabled=true, bounded, outputs)
    @test typeof(state[:reference].compiled) === typeof(state[:candidate].compiled)
    @test isequal(Base.invokelatest(_snapshot, state[:candidate], kind),
        Base.invokelatest(_snapshot, state[:reference], kind))
    @test Base.invokelatest(_scientific_types, state[:candidate]) ==
        Base.invokelatest(_scientific_types, state[:reference])
    reference_report = Base.invokelatest(Boundaries.planner_boundary_report, left)
    candidate_report = Base.invokelatest(Boundaries.planner_boundary_report, right)
    @test !reference_report.enabled
    @test reference_report.policy_selections == 3
    @test reference_report.scene_entries == reference_report.application_assemblies ==
        reference_report.scenario_assemblies == 0
    @test candidate_report.enabled
    @test candidate_report.policy_selections == 3
    @test candidate_report.scene_entries == candidate_report.application_assemblies ==
        candidate_report.scenario_assemblies == 1
    state[:left_ids] = Base.invokelatest(_identities, left)
    state[:right_ids] = Base.invokelatest(_identities, right)
    for key in keys(state[:left_ids].cells)
        @test state[:left_ids].cells[key] !== state[:right_ids].cells[key]
    end
    for _ in 1:steps
        Base.invokelatest(PSE.step!, state[:reference])
        Base.invokelatest(PSE.step!, state[:candidate])
        @test isequal(Base.invokelatest(_snapshot, state[:candidate], kind),
            Base.invokelatest(_snapshot, state[:reference], kind))
        @test Base.invokelatest(_scientific_types, state[:candidate]) ==
            Base.invokelatest(_scientific_types, state[:reference])
        new_left = Base.invokelatest(_identities, left)
        new_right = Base.invokelatest(_identities, right)
        _identity_transitions(state[:left_ids], state[:right_ids], new_left, new_right)
        state[:left_ids], state[:right_ids] = new_left, new_right
    end
    @test_throws ArgumentError Boundaries.enable_planner_boundaries!(left)
    @test Boundaries.enable_planner_boundaries!(right) === right
    return (ordinary=Base.invokelatest(Boundaries.planner_boundary_report, left),
        candidate=Base.invokelatest(Boundaries.planner_boundary_report, right),
        final_objects=length(PSE.object_ids(right)),
        interpretation=:correctness_and_types_only_timing_is_a_separate_gate)
end

function planner_width_checks(; widths=(4, 8), nobjects=2, steps=2,
    outputs=(:none, :all), bounded=false)
    reports = Any[]
    @testset "Cold planner boundaries preserve widening concrete model stacks" begin
        for nmodels in widths, retained in outputs
            left = Base.invokelatest(planner_width_fixture; nmodels, nobjects)
            right = Base.invokelatest(planner_width_fixture; nmodels, nobjects)
            report = Base.invokelatest(_compare_models, left, right;
                steps, outputs=retained, bounded)
            push!(reports, (; nmodels, outputs=retained, report))
        end
    end
    return (; passed=true, reports)
end

function planner_growth_checks(; nmodels=4, steps=3, outputs=:all, bounded=false)
    report = nothing
    @testset "Cold planner boundaries preserve growth and live identities" begin
        left = Base.invokelatest(planner_width_fixture; nmodels, growth=true)
        right = Base.invokelatest(planner_width_fixture; nmodels, growth=true)
        report = Base.invokelatest(_compare_models, left, right; steps, outputs, bounded)
        @test report.final_objects == 5
    end
    return (; passed=true, report)
end

function planner_pb_checks(; nobjects=2, steps=2, outputs=:all, bounded=false)
    isdefined(Main, :NativePBDriver) || error("Load pb_driver.jl first")
    driver = getfield(Main, :NativePBDriver)
    left = Base.invokelatest(driver.pb_native_fixture; native=false, nobjects, steps)
    right = Base.invokelatest(driver.pb_native_fixture; native=false, nobjects, steps)
    report = nothing
    @testset "Original PB kernels with cold planner boundaries" begin
        report = Base.invokelatest(_compare_models, left.model, right.model;
            kind=:pb, steps, outputs, bounded)
    end
    return (; passed=true, report)
end

function planner_xp_checks(; steps=2, outputs=:all, bounded=false)
    isdefined(Main, :NativeXPDriver) || error("Load xpalm_driver.jl first")
    driver = getfield(Main, :NativeXPDriver)
    left = Base.invokelatest(driver.xpalm_native_fixture; native=false, steps, seed=1)
    right = Base.invokelatest(driver.xpalm_native_fixture; native=false, steps, seed=1)
    report = nothing
    @testset "Original XP kernels and growth with cold planner boundaries" begin
        report = Base.invokelatest(_compare_models, left, right;
            kind=:xp, steps, outputs, bounded)
    end
    return (; passed=true, report)
end

end # module
