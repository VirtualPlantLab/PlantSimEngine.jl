module BoundedPreparationChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const BP = Main.BoundedPreparation

export bounded_table_checks, bounded_width_fixture, bounded_width_checks,
    bounded_growth_checks, bounded_preparation_checks

PSE.@process "bounded_width_probe" verbose=false
PSE.@process "bounded_growth_creator" verbose=false

struct WidthProbe{T} <: AbstractBounded_Width_ProbeModel
    coefficient::T
end
PSE.inputs_(::WidthProbe{T}) where {T} = (x=PSE.Required(T),)
PSE.outputs_(::WidthProbe{T}) where {T} = (value=zero(T), visits=0)
function PSE.run!(model::WidthProbe, status, environment, constants, context)
    status.visits += 1
    status.value = model.coefficient * status.x + oftype(status.x, status.visits)
    return nothing
end

struct GrowthCreator <: AbstractBounded_Growth_CreatorModel end
PSE.inputs_(::GrowthCreator) = (;)
PSE.outputs_(::GrowthCreator) = (births=0,)
function PSE.run!(::GrowthCreator, status, environment, constants, context)
    status.births >= 2 && return nothing
    status.births += 1
    PSE.register_object!(PSE.runtime_model(context), PSE.Object(10 + status.births;
        parent=0, kind=:width_unit, status=(x=Float32(10 + status.births),)))
    return nothing
end

"""Vary application width while organ count and every scientific status type stay fixed.

Private outputs avoid duplicate canonical writers without introducing one
variable per application into an organ's canonical status. Actual per-app
private visits/value remain observable after outputs=:none and are checked.
"""
function bounded_width_fixture(; nmodels=2, nobjects=2, T=Float32, growth=false)
    applications = Any[]
    growth && push!(applications, PSE.ModelSpec(GrowthCreator(); name=:creator,
        on=PSE.One(id=0), every=Hour(1)))
    for index in 1:nmodels
        push!(applications, PSE.ModelSpec(WidthProbe(T(index));
            name=Symbol(:width_, index), on=PSE.Many(kind=:width_unit),
            every=Hour(1), output_routing=(value=:stream_only, visits=:stream_only)))
    end
    organs = PSE.Object[PSE.Object(index; parent=0, kind=:width_unit,
        status=(x=T(index),)) for index in 1:nobjects]
    return PSE.CompositeModel(PSE.Object(0), organs...;
        applications, environment=(duration=Hour(1),))
end

function _snapshot(simulation)
    canonical = Dict{PSE.ObjectId,Any}()
    for object in PSE.model_objects(simulation.model)
        status = PSE.model_status(simulation.model, object.id)
        canonical[object.id] = status === nothing ? nothing : deepcopy(NamedTuple(status))
    end
    private = Dict(key => deepcopy(NamedTuple(view.status))
        for (key, view) in simulation.compiled.status_views_by_target)
    histories = Dict(key => deepcopy(collect(stream)) for (key, stream) in pairs(PSE.outputs(simulation)))
    topology = Dict(object.id => (parent=object.parent, kind=object.kind,
        geometry=PSE.geometry(object)) for object in PSE.model_objects(simulation.model))
    return (step=PSE.current_step(simulation), canonical, private, histories, topology)
end

function bounded_table_checks()
    @testset "Bounded metadata ordered names and non-dense slots" begin
        table = BP.BoundedSymbolTable((:entries, :first), (20, 10), (9, 3))
        @test collect(keys(table)) == [:entries, :first]
        @test collect(values(table)) == [20, 10]
        @test collect(pairs(table)) == [:entries => 20, :first => 10]
        @test table[:entries] === table.entries === 20
        @test table[:first] === table.first === 10
        @test table[9] === PSE._application_plans(table, 9) === 20
        @test table[3] === PSE._application_plans(table, 3) === 10
        @test_throws KeyError table[1]
        @test get(table, :missing, :fallback) === :fallback
        @test get(table, :first, :fallback) === 10
        @test haskey(table, :entries) && !haskey(table, :missing)
        @test propertynames(table) === (:entries, :first)
        empty_table = BP.BoundedSymbolTable((), (), ())
        @test isempty(empty_table)
        @test isempty(collect(empty_table))
        @test typeof(table) === typeof(empty_table)
    end
    return (passed=true, semantics=:authored_iteration_symbol_names_and_actual_slots)
end

function bounded_width_checks(; widths=(2, 4), nobjects=2, steps=2)
    reports = Any[]
    bounded_scenario_types = Any[]
    bounded_compiled_types = Any[]
    ordinary_scenario_types = Any[]
    status_types = Any[]
    @testset "Bound scenario width while preserving concrete scientific payloads" begin
        for nmodels in widths, outputs in (:none, :all)
            reference = PSE.run!(bounded_width_fixture(; nmodels, nobjects);
                steps=0, outputs)
            candidate = BP.prepare_bounded(bounded_width_fixture(; nmodels, nobjects);
                steps=0, outputs)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            for step in 1:steps
                PSE.step!(reference); PSE.step!(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
                for index in 1:nmodels, id in 1:nobjects
                    view = candidate.compiled.status_views_by_target[(Symbol(:width_, index), PSE.ObjectId(id))]
                    @test view.status.visits == step
                    @test view.status.value === Float32(index * id + step)
                    @test isconcretetype(typeof(view.status))
                end
            end
            report = BP.bounded_preparation_report(candidate)
            types = BP.bounded_type_report(candidate)
            @test report.scene_entries == report.scenario_plans == 1
            @test report.scene_shells >= 1
            @test report.metadata_symbol_tables > 0
            @test report.maximum_table_entries == nmodels
            @test report.selector_indexes == 1
            @test report.metadata_schedules == 1
            @test types.scenario_max_tuple_width <= 4
            push!(bounded_scenario_types, typeof(candidate.compiled.scenario_plan))
            push!(bounded_compiled_types, typeof(candidate.compiled))
            push!(ordinary_scenario_types, typeof(reference.compiled.scenario_plan))
            push!(status_types, types.scientific_status_types)
            push!(reports, (; nmodels, outputs, report, types,
                ordinary=BP.bounded_type_report(reference)))
        end
        @test length(unique(bounded_scenario_types)) == 1
        @test length(unique(bounded_compiled_types)) == 1
        @test length(unique(ordinary_scenario_types)) == length(unique(widths))
        @test all(types -> types == first(status_types), status_types)
    end
    return (; passed=true, reports,
        interpretation=:constant_organ_count_and_status_layout_as_application_count_varies)
end

function bounded_growth_checks()
    reports = Any[]
    @testset "Bounded metadata preserves live growth removal movement and histories" begin
        for outputs in (:none, :all)
            reference = PSE.run!(bounded_width_fixture(; growth=true); steps=0, outputs)
            candidate = BP.prepare_bounded(bounded_width_fixture(; growth=true); steps=0, outputs)
            initial_plan = candidate.compiled.scenario_plan
            initial_type = typeof(candidate.compiled)
            escaped = PSE.refvalue(PSE.model_status(candidate.model, 1), :x)
            for _ in 1:3
                PSE.step!(reference); PSE.step!(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
                @test candidate.compiled.scenario_plan === initial_plan
                @test typeof(candidate.compiled) === initial_type
                @test PSE.refvalue(PSE.model_status(candidate.model, 1), :x) === escaped
            end
            for simulation in (reference, candidate)
                PSE.remove_object!(simulation.model, 2)
                PSE.reparent_object!(simulation.model, 11, 1)
                PSE.move_object!(simulation.model, 1, (cell=:new_position,))
            end
            PSE.step!(reference); PSE.step!(candidate)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            @test typeof(candidate.compiled) === initial_type
            @test PSE.refvalue(PSE.model_status(candidate.model, 1), :x) === escaped
            report = BP.bounded_preparation_report(candidate)
            @test report.scene_shells >= 4
            push!(reports, (; outputs, report, types=BP.bounded_type_report(candidate)))
        end
    end
    return (; passed=true, reports)
end

bounded_preparation_checks() = (table=bounded_table_checks(),
    width=bounded_width_checks(), growth=bounded_growth_checks())

end # module
