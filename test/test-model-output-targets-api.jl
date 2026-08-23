using Dates
using PlantSimEngine
using Tables
using Test

PlantSimEngine.@process "output_targets_api_writer" verbose = false
PlantSimEngine.@process "output_targets_api_action" verbose = false

mutable struct OutputTargetsApiWriterModel <:
               AbstractOutput_Targets_Api_WriterModel
    table::Base.RefValue{Any}
    seen_types::Vector{DataType}
    seen_ids::Vector{Vector{ObjectId}}
    seen_lengths::Vector{Int}
    seen_columns::Vector{Tuple}
end

function OutputTargetsApiWriterModel(table)
    return OutputTargetsApiWriterModel(
        Ref{Any}(table),
        DataType[],
        Vector{ObjectId}[],
        Int[],
        Tuple[],
    )
end

PlantSimEngine.inputs_(::OutputTargetsApiWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputTargetsApiWriterModel) = NamedTuple()

struct OutputTargetsApiActionModel{F} <: AbstractOutput_Targets_Api_ActionModel
    action::F
end

PlantSimEngine.inputs_(::OutputTargetsApiActionModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputTargetsApiActionModel) = NamedTuple()

function PlantSimEngine.run!(
    model::OutputTargetsApiWriterModel,
    status,
    environment,
    constants,
    context,
)
    targets = output_targets(context, :organs)
    push!(model.seen_types, typeof(targets))
    push!(model.seen_ids, collect(object_ids(targets)))
    push!(model.seen_lengths, length(targets))
    push!(model.seen_columns, propertynames(targets.columns))
    assign_outputs!(targets, model.table[]; id=:object_id)
    return nothing
end

function PlantSimEngine.run!(
    model::OutputTargetsApiActionModel,
    status,
    environment,
    constants,
    context,
)
    model.action(context)
    return nothing
end

mutable struct OutputTargetsApiCountingIds <: AbstractVector{ObjectId}
    values::Vector{ObjectId}
    reads::Base.RefValue{Int}
end

Base.IndexStyle(::Type{OutputTargetsApiCountingIds}) = IndexLinear()
Base.size(ids::OutputTargetsApiCountingIds) = size(ids.values)
Base.axes(ids::OutputTargetsApiCountingIds) = axes(ids.values)

@inline function Base.getindex(ids::OutputTargetsApiCountingIds, index::Int)
    ids.reads[] += 1
    return ids.values[index]
end

function output_targets_api_scene(
    writer;
    leaf_ids=(:leaf_a, :leaf_b),
    vars=(incident_par=Default(0.0),),
)
    objects = Object[Object(:scene; scale=:Scene)]
    for leaf_id in leaf_ids
        push!(
            objects,
            Object(leaf_id; scale=:Leaf, parent=:scene),
        )
    end
    return CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                writer;
                name=:output_targets_api_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    organs=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=vars,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function output_targets_api_status(model, object_id)
    return model_object(model, object_id).status
end

function output_targets_api_failed_assignment(
    table;
    vars=(incident_par=Default(0.0),),
)
    writer = OutputTargetsApiWriterModel(table)
    model = output_targets_api_scene(writer; vars=vars)
    error = try
        run!(model; outputs=:none)
        nothing
    catch caught
        caught
    end
    return error, model
end

function output_targets_api_error_message(error)
    return lowercase(sprint(showerror, error))
end

function output_targets_api_capture(action)
    return try
        action()
        nothing
    catch caught
        caught
    end
end

@testset "public OutputTargets view and Tables column assignment" begin
    table = (
        object_id=ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_a)],
        source_topology_id=[:coffee_b, :coffee_a],
        incident_par=[20.0, 10.0],
        absorbed_par=Float32[2.0, 1.0],
        component_index=[22, 11],
    )
    @test Tables.istable(typeof(table))

    writer = OutputTargetsApiWriterModel(table)
    model = output_targets_api_scene(
        writer;
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Default(0.0),
        ),
    )
    simulation = run!(model; outputs=:none)

    @test isdefined(PlantSimEngine, :OutputTargets)
    @test isdefined(PlantSimEngine, :output_targets)
    @test isdefined(PlantSimEngine, :assign_outputs!)
    @test only(writer.seen_types) <: OutputTargets
    @test only(writer.seen_ids) ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    @test only(writer.seen_lengths) == 2
    @test only(writer.seen_columns) == (:incident_par, :absorbed_par)

    leaf_a = final_state(simulation, :leaf_a)
    leaf_b = final_state(simulation, :leaf_b)
    @test leaf_a.incident_par == 10.0
    @test leaf_a.absorbed_par == 1.0
    @test leaf_b.incident_par == 20.0
    @test leaf_b.absorbed_par == 2.0
end

@testset "public direct ID and NamedTuple assignment overload" begin
    ids = ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_a)]
    columns = (
        incident_par=[42.0, 21.0],
        absorbed_par=Float32[4.0, 2.0],
        source_element=[:element_b, :element_a],
    )
    writer = OutputTargetsApiActionModel() do context
        targets = output_targets(context, :organs)
        assigned = assign_outputs!(targets, ids, columns)
        @test assigned === targets
    end
    model = output_targets_api_scene(
        writer;
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Default(0.0),
        ),
    )
    simulation = run!(model; outputs=:none)

    @test final_state(simulation, :leaf_a).incident_par == 21.0
    @test final_state(simulation, :leaf_a).absorbed_par == 2.0
    @test final_state(simulation, :leaf_b).incident_par == 42.0
    @test final_state(simulation, :leaf_b).absorbed_par == 4.0
end

@testset "output_targets lookup validation" begin
    lookup_errors = Any[]
    writer = OutputTargetsApiActionModel() do context
        push!(
            lookup_errors,
            output_targets_api_capture(
                () -> output_targets(context, :missing_group),
            ),
        )
        push!(
            lookup_errors,
            output_targets_api_capture(
                () -> output_targets(context, "organs"),
            ),
        )
        assign_outputs!(
            output_targets(context, :organs),
            ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)],
            (incident_par=[1.0, 2.0],),
        )
    end
    model = output_targets_api_scene(writer)
    run!(model; outputs=:none)

    @test length(lookup_errors) == 2
    @test all(error -> error isa ArgumentError, lookup_errors)
    missing_message = output_targets_api_error_message(lookup_errors[1])
    @test occursin("missing_group", missing_message)
    @test occursin("available groups", missing_message)
    @test occursin("organs", missing_message)
    invalid_message = output_targets_api_error_message(lookup_errors[2])
    @test occursin("symbol", invalid_message)
    @test occursin("string", invalid_message)

    invalid_context_error = output_targets_api_capture(
        () -> output_targets(nothing, :organs),
    )
    @test invalid_context_error isa ArgumentError
    invalid_context_message = output_targets_api_error_message(
        invalid_context_error,
    )
    @test occursin("runcontext", invalid_context_message)
    @test occursin("nothing", invalid_context_message)
end

@testset "aliased source-destination mappings are rejected" begin
    view_alias_error = Ref{Any}(nothing)
    cross_carrier_view_alias_error = Ref{Any}(nothing)
    cross_carrier_alias_error = Ref{Any}(nothing)
    permuted_alias_error = Ref{Any}(nothing)
    values_after_view_alias = Ref(Float64[])
    values_after_cross_carrier_view_alias = Ref(Float64[])
    values_after_cross_carrier_alias = Ref(Float64[])
    writer = OutputTargetsApiActionModel() do context
        targets = output_targets(context, :organs)
        targets.columns.incident_par[1] = 10.0
        targets.columns.incident_par[2] = 20.0
        exact_ids = collect(object_ids(targets))
        @test assign_outputs!(
            targets,
            exact_ids,
            (incident_par=targets.columns.incident_par,),
        ) === targets
        reversed_view = @view targets.columns.incident_par[2:-1:1]
        view_alias_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                exact_ids,
                (incident_par=reversed_view,),
            )
        end
        values_after_view_alias[] = collect(targets.columns.incident_par)
        object_source = PlantSimEngine.ObjectRefVector(
            parent(targets.columns.incident_par),
        )
        object_reversed_view = @view object_source[2:-1:1]
        @test Base.mightalias(
            targets.columns.incident_par,
            object_reversed_view,
        )
        cross_carrier_view_alias_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                exact_ids,
                (incident_par=object_reversed_view,),
            )
        end
        values_after_cross_carrier_view_alias[] = collect(
            targets.columns.incident_par,
        )
        cross_carrier_alias_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                reverse(exact_ids),
                (incident_par=object_source,),
            )
        end
        values_after_cross_carrier_alias[] = collect(
            targets.columns.incident_par,
        )
        permuted_alias_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                reverse(exact_ids),
                (incident_par=targets.columns.incident_par,),
            )
        end
    end
    model = output_targets_api_scene(writer)
    simulation = run!(model; outputs=:none)

    @test view_alias_error[] isa ArgumentError
    view_message = output_targets_api_error_message(view_alias_error[])
    @test occursin("differently ordered", view_message)
    @test occursin("source", view_message)
    @test values_after_view_alias[] == [10.0, 20.0]
    @test cross_carrier_view_alias_error[] isa ArgumentError
    cross_carrier_view_message = output_targets_api_error_message(
        cross_carrier_view_alias_error[],
    )
    @test occursin("differently ordered", cross_carrier_view_message)
    @test occursin("source", cross_carrier_view_message)
    @test values_after_cross_carrier_view_alias[] == [10.0, 20.0]
    @test cross_carrier_alias_error[] isa ArgumentError
    cross_carrier_message = output_targets_api_error_message(
        cross_carrier_alias_error[],
    )
    @test occursin("differently ordered", cross_carrier_message)
    @test occursin("source", cross_carrier_message)
    @test values_after_cross_carrier_alias[] == [10.0, 20.0]
    @test permuted_alias_error[] isa ArgumentError
    permuted_message = output_targets_api_error_message(
        permuted_alias_error[],
    )
    @test occursin("differently ordered", permuted_message)
    @test occursin("source", permuted_message)
    @test final_state(simulation, :leaf_a).incident_par == 10.0
    @test final_state(simulation, :leaf_b).incident_par == 20.0
end

@testset "cross-column source alias is rejected atomically" begin
    alias_error = Ref{Any}(nothing)
    incident_after_error = Ref(Float64[])
    absorbed_after_error = Ref(Float64[])
    writer = OutputTargetsApiActionModel() do context
        targets = output_targets(context, :organs)
        targets.columns.incident_par[1] = 10.0
        targets.columns.incident_par[2] = 20.0
        targets.columns.absorbed_par[1] = 1.0
        targets.columns.absorbed_par[2] = 2.0
        exact_ids = collect(object_ids(targets))
        alias_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                exact_ids,
                (
                    incident_par=[100.0, 200.0],
                    absorbed_par=targets.columns.incident_par,
                ),
            )
        end
        incident_after_error[] = collect(targets.columns.incident_par)
        absorbed_after_error[] = collect(targets.columns.absorbed_par)
    end
    model = output_targets_api_scene(
        writer;
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Default(0.0),
        ),
    )
    simulation = run!(model; outputs=:none)

    @test alias_error[] isa ArgumentError
    message = output_targets_api_error_message(alias_error[])
    @test occursin("destination column", message)
    @test occursin("source", message)
    @test incident_after_error[] == [10.0, 20.0]
    @test absorbed_after_error[] == [1.0, 2.0]
    @test final_state(simulation, :leaf_a).incident_par == 10.0
    @test final_state(simulation, :leaf_b).incident_par == 20.0
    @test final_state(simulation, :leaf_a).absorbed_par == 1.0
    @test final_state(simulation, :leaf_b).absorbed_par == 2.0
end

@testset "exact and permuted result mappings are cached by ID-column identity" begin
    permuted_reads = Ref(0)
    permuted_ids = OutputTargetsApiCountingIds(
        ObjectId[
            ObjectId(:leaf_c),
            ObjectId(:leaf_a),
            ObjectId(:leaf_b),
        ],
        permuted_reads,
    )
    permuted_incident = [30.0, 10.0, 20.0]
    permuted_absorbed = [3.0, 1.0, 2.0]
    writer = OutputTargetsApiWriterModel((
        object_id=permuted_ids,
        incident_par=permuted_incident,
        absorbed_par=permuted_absorbed,
    ))
    model = output_targets_api_scene(
        writer;
        leaf_ids=(:leaf_a, :leaf_b, :leaf_c),
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Default(0.0),
        ),
    )

    simulation = run!(model; outputs=:none)
    first_permuted_reads = permuted_reads[]
    @test first_permuted_reads >= length(permuted_ids)
    @test final_state(simulation, :leaf_a).incident_par == 10.0
    @test final_state(simulation, :leaf_b).incident_par == 20.0
    @test final_state(simulation, :leaf_c).incident_par == 30.0

    permuted_incident .= (300.0, 100.0, 200.0)
    permuted_absorbed .= (30.0, 10.0, 20.0)
    continue!(simulation)
    @test permuted_reads[] == first_permuted_reads
    @test final_state(simulation, :leaf_a).incident_par == 100.0
    @test final_state(simulation, :leaf_b).incident_par == 200.0
    @test final_state(simulation, :leaf_c).incident_par == 300.0

    exact_reads = Ref(0)
    exact_ids = OutputTargetsApiCountingIds(
        ObjectId[
            ObjectId(:leaf_a),
            ObjectId(:leaf_b),
            ObjectId(:leaf_c),
        ],
        exact_reads,
    )
    exact_incident = [1.0, 2.0, 3.0]
    exact_absorbed = [0.1, 0.2, 0.3]
    writer.table[] = (
        object_id=exact_ids,
        incident_par=exact_incident,
        absorbed_par=exact_absorbed,
    )
    continue!(simulation)
    first_exact_reads = exact_reads[]
    @test first_exact_reads >= length(exact_ids)
    @test final_state(simulation, :leaf_a).incident_par == 1.0
    @test final_state(simulation, :leaf_b).incident_par == 2.0
    @test final_state(simulation, :leaf_c).incident_par == 3.0

    exact_incident .= (11.0, 22.0, 33.0)
    exact_absorbed .= (1.1, 2.2, 3.3)
    continue!(simulation)
    @test exact_reads[] == first_exact_reads
    @test final_state(simulation, :leaf_a).incident_par == 11.0
    @test final_state(simulation, :leaf_b).incident_par == 22.0
    @test final_state(simulation, :leaf_c).incident_par == 33.0
end

@testset "failed remapping cannot poison a cached permutation" begin
    valid_ids = ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_a)]
    invalid_ids = ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_a)]
    invalid_error = Ref{Any}(nothing)
    recovery_error = Ref{Any}(nothing)
    values_after_invalid = Ref(Float64[])
    writer = OutputTargetsApiActionModel() do context
        targets = output_targets(context, :organs)
        assign_outputs!(
            targets,
            valid_ids,
            (incident_par=[20.0, 10.0],),
        )
        invalid_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                invalid_ids,
                (incident_par=[91.0, 92.0],),
            )
        end
        values_after_invalid[] = collect(targets.columns.incident_par)
        recovery_error[] = output_targets_api_capture() do
            assign_outputs!(
                targets,
                valid_ids,
                (incident_par=[200.0, 100.0],),
            )
        end
    end
    model = output_targets_api_scene(writer)
    simulation = run!(model; outputs=:none)

    @test invalid_error[] isa ArgumentError
    invalid_message = output_targets_api_error_message(invalid_error[])
    @test occursin("duplicate", invalid_message)
    @test values_after_invalid[] == [10.0, 20.0]
    @test isnothing(recovery_error[])
    @test final_state(simulation, :leaf_a).incident_par == 100.0
    @test final_state(simulation, :leaf_b).incident_par == 200.0
end

@testset "Tables row access and heterogeneous output columns" begin
    column_table = (
        object_id=ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_a)],
        incident_par=Float32[2.5, 1.25],
        organ_label=[:leaf_b, :leaf_a],
        hit_count=Int32[20, 10],
    )
    writer = OutputTargetsApiWriterModel(column_table)
    model = output_targets_api_scene(
        writer;
        vars=(
            incident_par=Default(0.0),
            organ_label=Default(:unset),
            hit_count=Default(0),
        ),
    )
    simulation = run!(model; outputs=:none)

    leaf_a = final_state(simulation, :leaf_a)
    leaf_b = final_state(simulation, :leaf_b)
    @test leaf_a.incident_par == 1.25
    @test leaf_a.organ_label === :leaf_a
    @test leaf_a.hit_count == 10
    @test leaf_b.incident_par == 2.5
    @test leaf_b.organ_label === :leaf_b
    @test leaf_b.hit_count == 20

    row_table = [
        (
            object_id=ObjectId(:leaf_a),
            incident_par=3.5f0,
            organ_label=:row_a,
            hit_count=Int16(30),
        ),
        (
            object_id=ObjectId(:leaf_b),
            incident_par=4.5f0,
            organ_label=:row_b,
            hit_count=Int16(40),
        ),
    ]
    @test Tables.rowaccess(typeof(row_table))
    writer.table[] = row_table
    continue!(simulation)

    leaf_a = final_state(simulation, :leaf_a)
    leaf_b = final_state(simulation, :leaf_b)
    @test leaf_a.incident_par == 3.5
    @test leaf_a.organ_label === :row_a
    @test leaf_a.hit_count == 30
    @test leaf_b.incident_par == 4.5
    @test leaf_b.organ_label === :row_b
    @test leaf_b.hit_count == 40
end

@testset "identified table schema and conversion errors are atomic" begin
    missing_id_table = (
        source_node_id=ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)],
        incident_par=[91.0, 92.0],
    )
    error, model = output_targets_api_failed_assignment(missing_id_table)
    @test error isa ArgumentError
    message = output_targets_api_error_message(error)
    @test occursin("missing id column", message)
    @test occursin("object_id", message)
    @test output_targets_api_status(model, :leaf_a).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_b).incident_par == 0.0

    inconsistent_table = (
        object_id=ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)],
        incident_par=[91.0],
    )
    error, model = output_targets_api_failed_assignment(inconsistent_table)
    @test error isa DimensionMismatch
    message = output_targets_api_error_message(error)
    @test occursin("incident_par", message)
    @test occursin("id column", message)
    @test output_targets_api_status(model, :leaf_a).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_b).incident_par == 0.0

    invalid_late_column = (
        object_id=ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)],
        incident_par=[91.0, 92.0],
        hit_count=["not-an-integer", "still-not-an-integer"],
    )
    error, model = output_targets_api_failed_assignment(
        invalid_late_column;
        vars=(
            incident_par=Default(0.0),
            hit_count=Default(0),
        ),
    )
    @test error isa MethodError
    message = output_targets_api_error_message(error)
    @test occursin("convert", message)
    @test occursin("string", message)
    @test occursin("int", message)
    @test output_targets_api_status(model, :leaf_a).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_a).hit_count == 0
    @test output_targets_api_status(model, :leaf_b).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_b).hit_count == 0
end

@testset "exact coverage errors are actionable and atomic" begin
    invalid_tables = (
        unknown=(
            table=(
                object_id=ObjectId[
                    ObjectId(:leaf_a),
                    ObjectId(:ghost_leaf),
                ],
                incident_par=[91.0, 92.0],
            ),
            fragments=("unknown", "ghost_leaf"),
        ),
        duplicate=(
            table=(
                object_id=ObjectId[
                    ObjectId(:leaf_a),
                    ObjectId(:leaf_a),
                ],
                incident_par=[91.0, 92.0],
            ),
            fragments=("duplicate", "leaf_a"),
        ),
        missing=(
            table=(
                object_id=ObjectId[ObjectId(:leaf_a)],
                incident_par=[91.0],
            ),
            fragments=("missing", "leaf_b"),
        ),
        extra=(
            table=(
                object_id=ObjectId[
                    ObjectId(:leaf_a),
                    ObjectId(:leaf_b),
                    ObjectId(:extra_leaf),
                ],
                incident_par=[91.0, 92.0, 93.0],
            ),
            fragments=("extra", "extra_leaf"),
        ),
    )

    for (case, invalid) in pairs(invalid_tables)
        @testset "$(case) ID" begin
            error, model = output_targets_api_failed_assignment(invalid.table)
            @test error isa Exception
            message = error isa Exception ? output_targets_api_error_message(error) : ""
            for fragment in invalid.fragments
                @test occursin(fragment, message)
            end
            @test output_targets_api_status(model, :leaf_a).incident_par == 0.0
            @test output_targets_api_status(model, :leaf_b).incident_par == 0.0
        end
    end

    missing_column_table = (
        object_id=ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)],
        incident_par=[91.0, 92.0],
    )
    error, model = output_targets_api_failed_assignment(
        missing_column_table;
        vars=(
            incident_par=Default(0.0),
            absorbed_par=Default(0.0),
        ),
    )
    @test error isa Exception
    message = error isa Exception ? output_targets_api_error_message(error) : ""
    @test occursin("missing", message)
    @test occursin("absorbed_par", message)
    @test output_targets_api_status(model, :leaf_a).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_a).absorbed_par == 0.0
    @test output_targets_api_status(model, :leaf_b).incident_par == 0.0
    @test output_targets_api_status(model, :leaf_b).absorbed_par == 0.0
end

@testset "lifecycle invalidates a cached output permutation" begin
    reads = Ref(0)
    ids = OutputTargetsApiCountingIds(
        ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_a)],
        reads,
    )
    values = [20.0, 10.0]
    writer = OutputTargetsApiWriterModel((
        object_id=ids,
        incident_par=values,
    ))
    model = output_targets_api_scene(writer)
    simulation = run!(model; outputs=:none)
    reads_before_lifecycle = reads[]
    @test reads_before_lifecycle >= 2

    register_object!(
        model,
        Object(:late_leaf; scale=:Leaf);
        parent=:scene,
    )
    push!(ids.values, ObjectId(:late_leaf))
    push!(values, 30.0)
    continue!(simulation)
    reads_after_lifecycle = reads[]
    @test reads_after_lifecycle > reads_before_lifecycle
    @test final_state(simulation, :leaf_a).incident_par == 10.0
    @test final_state(simulation, :leaf_b).incident_par == 20.0
    @test final_state(simulation, :late_leaf).incident_par == 30.0
    @test Set(last(writer.seen_ids)) == Set(ObjectId[
        ObjectId(:leaf_a),
        ObjectId(:leaf_b),
        ObjectId(:late_leaf),
    ])

    values .= (11.0, 22.0, 33.0)
    continue!(simulation)
    @test reads[] == reads_after_lifecycle
    @test final_state(simulation, :leaf_a).incident_par == 22.0
    @test final_state(simulation, :leaf_b).incident_par == 11.0
    @test final_state(simulation, :late_leaf).incident_par == 33.0
end

@testset "empty targets refresh to a typed lifecycle assignment" begin
    reads = Ref(0)
    ids = OutputTargetsApiCountingIds(ObjectId[], reads)
    values = Float64[]
    writer = OutputTargetsApiWriterModel((
        object_id=ids,
        incident_par=values,
    ))
    model = output_targets_api_scene(writer; leaf_ids=())
    simulation = run!(model; outputs=:none)

    @test only(writer.seen_lengths) == 0
    @test isempty(only(writer.seen_ids))
    @test reads[] == 0

    register_object!(
        model,
        Object(:first_leaf; scale=:Leaf);
        parent=:scene,
    )
    push!(ids.values, ObjectId(:first_leaf))
    push!(values, 7.5)
    continue!(simulation)

    @test reads[] > 0
    @test last(writer.seen_lengths) == 1
    @test last(writer.seen_ids) == ObjectId[ObjectId(:first_leaf)]
    @test final_state(simulation, :first_leaf).incident_par == 7.5
end
