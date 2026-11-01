module NativeCallChecks

using Dates
using Test
using PlantSimEngine
import ..ReusableProgram
const PSE = PlantSimEngine
const RP = ReusableProgram

PSE.@process "native_call_grandchild" verbose = false
struct Grandchild <: AbstractNative_Call_GrandchildModel end
PSE.inputs_(::Grandchild) = NamedTuple()
PSE.outputs_(::Grandchild) = (grand_count=0, grand_value=0.0)
PSE.environment_inputs_(::Grandchild) = (delta=0.0,)
function PSE.run!(::Grandchild, status, environment, constants, context)
    status.grand_count += 1
    status.grand_value += environment.delta
    return nothing
end

PSE.@process "native_call_child" verbose = false
struct Child <: AbstractNative_Call_ChildModel end
PSE.inputs_(::Child) = (grand_count=Required(Int), grand_value=Required(Float64))
PSE.outputs_(::Child) = (child_count=0, child_seen=0.0, child_alias=true)
PSE.environment_inputs_(::Child) = (delta=0.0,)
PSE.dep(::Child) = (grand=Call(One(within=Self(), application=:grand)),)
function PSE.run!(::Child, status, environment, constants, context)
    status.child_count += 1
    for target in PSE.call_targets(context, :grand)
        status.child_alias &= PSE.refvalue(status, :grand_value) === PSE.refvalue(target.status, :grand_value)
        # A published nested call must remain unpublished when its ancestor was
        # invoked with publish=false. Scientific mutation must still happen.
        PSE.run_call!(target; publish=true)
        status.child_seen = target.status.grand_value
    end
    return nothing
end

PSE.@process "native_call_parent" verbose = false
struct Parent <: AbstractNative_Call_ParentModel
    publish_child::Bool
    conditional::Bool
    selected_id::Union{Nothing,Int}
    direct_target::Bool
end
PSE.inputs_(::Parent) = (child_count=Required(Int),)
PSE.outputs_(::Parent) = (
    parent_count=0, observed_targets=0, selected_targets=0,
    parent_seen=0, parent_alias=true, result_alias=true,
)
PSE.environment_inputs_(::Parent) = (delta=0.0,)
PSE.dep(::Parent) = (child=Call(One(within=Self(), application=:child)),)
function PSE.run!(model::Parent, status, environment, constants, context)
    status.parent_count += 1
    targets = PSE.call_targets(context, :child)
    status.observed_targets = length(targets)
    status.selected_targets = 0
    for target in targets
        status.parent_alias &= PSE.refvalue(status, :child_count) === PSE.refvalue(target.status, :child_count)
    end
    selected_here = isnothing(model.selected_id) ||
        any(target -> target.object_id == ObjectId(model.selected_id), targets)
    if (!model.conditional || iseven(status.parent_count)) && selected_here
        if model.direct_target
            for target in targets
                if isnothing(model.selected_id) || target.object_id == ObjectId(model.selected_id)
                    PSE.run_call!(target; publish=model.publish_child)
                    status.selected_targets += 1
                    status.result_alias &= PSE.refvalue(status, :child_count) === PSE.refvalue(target.status, :child_count)
                end
            end
        else
            selected = PSE.run_call!(context, :child;
                publish=model.publish_child, objects=model.selected_id)
            status.selected_targets = length(selected)
            for target in selected
                status.result_alias &= PSE.refvalue(status, :child_count) === PSE.refvalue(target.status, :child_count)
            end
        end
    end
    status.parent_seen = status.child_count
    return nothing
end

PSE.@process "native_call_owner_probe" verbose = false
struct OwnerProbe <: AbstractNative_Call_Owner_ProbeModel end
PSE.inputs_(::OwnerProbe) = NamedTuple()
PSE.outputs_(::OwnerProbe) = NamedTuple()

PSE.@process "native_call_external_input" verbose = false
struct ExternalInput <: AbstractNative_Call_External_InputModel end
PSE.inputs_(::ExternalInput) = (external=Required(Float64),)
PSE.outputs_(::ExternalInput) = (external_seen=0.0,)
PSE.environment_inputs_(::ExternalInput) = (delta=0.0,)
function PSE.run!(::ExternalInput, status, environment, constants, context)
    status.external_seen = status.external + environment.delta
    return nothing
end

function _specs(parent)
    # Authored children first: an accidental scheduled child would be counted
    # even on steps where the parent intentionally makes no call.
    return (
        ModelSpec(Grandchild(); name=:grand, on=Many(kind=:organ), every=Day(1)),
        ModelSpec(Child(); name=:child, on=Many(kind=:organ), every=Day(1)),
        ModelSpec(parent; name=:parent, on=Many(kind=:organ), every=Day(1)),
    )
end

function _ordinary(specs, ids, steps, environment)
    model = CompositeModel(
        (Object(id; kind=:organ) for id in ids)...;
        applications=specs, environment=merge(environment, (duration=Day(1),)),
    )
    return PSE.run!(model; steps, outputs=:all)
end

function _retained_rows(state, specs)
    schemas = Dict(spec.name => keys(PSE.outputs_(spec)) for spec in specs)
    rows = NamedTuple[]
    for publication in state.publications, variable in schemas[publication.application]
        push!(rows, (
            timestep=publication.step, application_id=publication.application,
            object_id=publication.object_id, variable,
            value=publication.values[variable],
        ))
    end
    sort!(rows; by=row -> (row.timestep, string(row.object_id), string(row.variable)))
    return rows
end

function _ordinary_rows(simulation)
    return [
        (timestep=row.timestep, application_id=row.application_id,
            object_id=row.object_id, variable=row.variable, value=row.value)
        for row in PSE.collect_outputs(simulation; sink=nothing)
    ]
end

function run_checks()
    result = @testset "Native same-object manual calls" begin
        @testset "original kernels, call conditions and publications" begin
            ids = [10, 20]
            environment = (delta=2.0,)
            steps = 3
            variants = (
                Parent(false, false, nothing, false),
                Parent(true, false, nothing, false),
                Parent(true, true, nothing, false),
                Parent(true, false, 20, false),
                Parent(true, true, 20, true),
            )
            for parent in variants
                specs = _specs(parent)
                program = RP.prepare(specs)
                @test length(program.regions) == 1
                @test only(program.regions).name == :parent
                state = RP.instantiate(program, map(spec -> spec.model, specs),
                    ids, fill(:organ, length(ids)); retain=true)
                for _ in 1:steps
                    RP.step!(state, environment)
                end
                ordinary = _ordinary(specs, ids, steps, environment)
                for (i, id) in enumerate(ids)
                    expected = PSE.final_state(ordinary, ObjectId(id))
                    for variable in keys(expected)
                        @test state.statuses[i][variable] === expected[variable]
                    end
                    calls = count(step -> (!parent.conditional || iseven(step)) &&
                        (isnothing(parent.selected_id) || id == parent.selected_id), 1:steps)
                    @test state.statuses[i].parent_count == steps
                    @test state.statuses[i].child_count == calls
                    @test state.statuses[i].grand_count == calls
                    @test state.statuses[i].child_seen == 2.0 * calls
                    @test state.statuses[i].observed_targets == 1
                    @test state.statuses[i].parent_alias
                    @test state.statuses[i].child_alias
                    @test state.statuses[i].result_alias
                end
                # Public ordinary collection sorts application streams. Compare
                # per-stream sample order and values, without inventing a public
                # cross-application ordering promise for collect_outputs.
                @test isequal(_retained_rows(state, specs), _ordinary_rows(ordinary))
                expected_order = Tuple{Symbol,Int,Int}[]
                for step in 1:steps, id in ids
                    called = (!parent.conditional || iseven(step)) &&
                        (isnothing(parent.selected_id) || id == parent.selected_id)
                    if called && parent.publish_child
                        push!(expected_order, (:grand, id, step), (:child, id, step))
                    end
                    push!(expected_order, (:parent, id, step))
                end
                @test [(p.application, p.object_id, p.step) for p in state.publications] == expected_order
                @test all(p -> p.values.parent_count == p.step, state.publications)
                if !parent.publish_child
                    @test all(p -> p.application == :parent, state.publications)
                    @test first(state.publications).values.child_count == 1
                    @test first(state.publications).values.grand_count == 1
                    @test last(state.publications).values.child_count == 3
                end
            end
        end

        @testset "unsupported graph ownership fails during preparation" begin
            target(name) = One(within=Self(), application=name)
            a = ModelSpec(OwnerProbe(); name=:a, on=Many(kind=:organ), every=Day(1),
                calls=(next=target(:b),))
            b = ModelSpec(OwnerProbe(); name=:b, on=Many(kind=:organ), every=Day(1),
                calls=(next=target(:a),))
            @test_throws ArgumentError RP.prepare((a, b))
            specs = _specs(Parent(true, false, nothing, false))
            other = ModelSpec(OwnerProbe(); name=:other_owner,
                on=Many(kind=:organ), every=Day(1), calls=(child=target(:child),))
            @test_throws ArgumentError RP.prepare((specs..., other))
        end

        @testset "typed supplied Required input" begin
            spec = ModelSpec(ExternalInput(); name=:external,
                on=Many(kind=:organ), every=Day(1))
            @test_throws ArgumentError RP.prepare((spec,))
            program = RP.prepare((spec,); initial=(external=2.0,))
            state = RP.instantiate(program, (spec.model,), [1], [:organ];
                initial=(external=3.0,), retain=true)
            RP.step!(state, (delta=4.0,))
            @test state.statuses[1].external_seen == 7.0
            @test only(state.publications).values.external_seen == 7.0
            @test_throws ArgumentError RP.instantiate(program, (spec.model,), [1], [:organ])
            @test_throws ArgumentError RP.instantiate(program, (spec.model,), [1], [:organ];
                initial=(external=3,))
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes + counts.cumulative_passes,
        fails=counts.fails + counts.cumulative_fails,
        errors=counts.errors + counts.cumulative_errors)
end

end # module NativeCallChecks
