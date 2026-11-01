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

PSE.@process "native_call_late_parent" verbose = false
struct LateParent <: AbstractNative_Call_Late_ParentModel end
PSE.inputs_(::LateParent) = NamedTuple()
PSE.outputs_(::LateParent) = (late_parent_runs=0,)
PSE.dep(::LateParent) = (child=Call(One(within=Self(), application=:late_child)),)
function PSE.run!(::LateParent, status, environment, constants, context)
    PSE.run_call!(context, :child; publish=true)
    status.late_parent_runs += 1
    return nothing
end
PSE.@process "native_call_late_writer" verbose = false
struct LateWriter <: AbstractNative_Call_Late_WriterModel end
PSE.inputs_(::LateWriter) = NamedTuple()
PSE.outputs_(::LateWriter) = (late_x=2.0,)
function PSE.run!(::LateWriter, status, environment, constants, context)
    status.late_x = 7.0
    return nothing
end
PSE.@process "native_call_late_child" verbose = false
struct LateChild <: AbstractNative_Call_Late_ChildModel end
PSE.inputs_(::LateChild) = (late_x=Required(Float64),)
PSE.outputs_(::LateChild) = (late_seen=-Inf,)
function PSE.run!(::LateChild, status, environment, constants, context)
    status.late_seen = status.late_x
    return nothing
end

PSE.@process "native_call_double" verbose = false
struct DoubleCaller <: AbstractNative_Call_DoubleModel end
PSE.inputs_(::DoubleCaller) = NamedTuple()
PSE.outputs_(::DoubleCaller) = (double_runs=0,)
PSE.dep(::DoubleCaller) = (grand=Call(One(within=Self(), application=:grand)),)
function PSE.run!(::DoubleCaller, status, environment, constants, context)
    PSE.run_call!(context, :grand; publish=true)
    PSE.run_call!(context, :grand; publish=true)
    status.double_runs += 1
    return nothing
end

PSE.@process "native_call_invalid_selection" verbose = false
struct InvalidSelection <: AbstractNative_Call_Invalid_SelectionModel end
PSE.inputs_(::InvalidSelection) = NamedTuple()
PSE.outputs_(::InvalidSelection) = (invalid_runs=0,)
PSE.dep(::InvalidSelection) = (grand=Call(One(within=Self(), application=:grand)),)
function PSE.run!(::InvalidSelection, status, environment, constants, context)
    PSE.run_call!(context, :grand; objects=999, publish=true)
    status.invalid_runs += 1
    return nothing
end

PSE.@process "native_call_skipped" verbose = false
struct SkippedCaller <: AbstractNative_Call_SkippedModel end
PSE.inputs_(::SkippedCaller) = NamedTuple()
PSE.outputs_(::SkippedCaller) = (skipped_runs=0,)
PSE.dep(::SkippedCaller) = (grand=Call(One(within=Self(), application=:grand)),)
function PSE.run!(::SkippedCaller, status, environment, constants, context)
    status.skipped_runs += 1
    return nothing
end

PSE.@process "native_call_contract_source" verbose = false
struct ContractSource <: AbstractNative_Call_Contract_SourceModel
    unit::Symbol
end
PSE.inputs_(::ContractSource) = NamedTuple()
PSE.outputs_(::ContractSource) = (contractual=1.0,)
PSE.variable_contracts_(model::ContractSource) = (contractual=VariableContract(unit=model.unit),)
PSE.@process "native_call_contract_consumer" verbose = false
struct ContractConsumer <: AbstractNative_Call_Contract_ConsumerModel
    unit::Symbol
end
PSE.inputs_(::ContractConsumer) = (contractual=Required(Float64),)
PSE.outputs_(::ContractConsumer) = (contract_seen=0.0,)
PSE.variable_contracts_(model::ContractConsumer) = (contractual=VariableContract(unit=model.unit),)

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

        @testset "call-only inputs retain authored root order" begin
            specs = (
                ModelSpec(LateParent(); name=:late_parent, on=Many(kind=:organ), every=Day(1)),
                ModelSpec(LateWriter(); name=:late_writer, on=Many(kind=:organ), every=Day(1)),
                ModelSpec(LateChild(); name=:late_child, on=Many(kind=:organ), every=Day(1)),
            )
            program = RP.prepare(specs)
            @test map(region -> region.name, program.regions) == (:late_parent, :late_writer)
            state = RP.instantiate(program, map(spec -> spec.model, specs), [10], [:organ]; retain=true)
            observed = Float64[]
            for _ in 1:2
                RP.step!(state, NamedTuple())
                push!(observed, only(state.statuses).late_seen)
            end
            ordinary = _ordinary(specs, [10], 2, NamedTuple())
            @test observed == [2.0, 7.0]
            original_seen = [row.value for row in PSE.collect_outputs(ordinary, ObjectId(10), :late_seen; sink=nothing)]
            @test original_seen == observed
            @test isequal(_retained_rows(state, specs), _ordinary_rows(ordinary))
        end

        @testset "repeated publication replaces the same step sample" begin
            specs = (
                ModelSpec(DoubleCaller(); name=:double, on=Many(kind=:organ), every=Day(1)),
                ModelSpec(Grandchild(); name=:grand, on=Many(kind=:organ), every=Day(1)),
            )
            state = RP.instantiate(RP.prepare(specs), map(spec -> spec.model, specs),
                [10], [:organ]; retain=true)
            for _ in 1:2
                RP.step!(state, (delta=2.0,))
            end
            ordinary = _ordinary(specs, [10], 2, (delta=2.0,))
            publications = filter(p -> p.application == :grand, state.publications)
            @test length(publications) == 2
            @test [p.step for p in publications] == [1, 2]
            @test [p.values.grand_count for p in publications] == [2, 4]
            @test only(state.statuses).grand_count == 4
            @test isequal(_retained_rows(state, specs), _ordinary_rows(ordinary))
        end

        @testset "invalid selected object fails before scientific mutation" begin
            specs = (
                ModelSpec(InvalidSelection(); name=:invalid, on=Many(kind=:organ), every=Day(1)),
                ModelSpec(Grandchild(); name=:grand, on=Many(kind=:organ), every=Day(1)),
            )
            state = RP.instantiate(RP.prepare(specs), map(spec -> spec.model, specs),
                [10], [:organ]; retain=true)
            before = NamedTuple(only(state.statuses))
            @test_throws Exception RP.step!(state, (delta=2.0,))
            @test NamedTuple(only(state.statuses)) == before
            @test isempty(state.publications)
            @test state.step == 0
            scene = CompositeModel(Object(10; kind=:organ); applications=specs,
                environment=(delta=2.0, duration=Day(1)))
            ordinary = PSE.run!(scene; steps=0, outputs=:all)
            original_before = PSE.final_state(ordinary, ObjectId(10))
            @test_throws Exception PSE.step!(ordinary)
            @test PSE.final_state(ordinary, ObjectId(10)) == original_before
        end

        @testset "declared child environment schema and skipped execution" begin
            specs = (
                ModelSpec(SkippedCaller(); name=:skipped, on=Many(kind=:organ), every=Day(1)),
                ModelSpec(Grandchild(); name=:grand, on=Many(kind=:organ), every=Day(1)),
            )
            state = RP.instantiate(RP.prepare(specs), map(spec -> spec.model, specs),
                [10], [:organ]; retain=true)
            # PSE validates every declared environment source during ordinary
            # preparation, even if a conditional caller never enters the child.
            @test_throws Exception RP.step!(state,NamedTuple())
            @test_throws Exception _ordinary(specs,[10],1,NamedTuple())
            @test only(state.statuses).skipped_runs == 0
            @test isempty(state.publications)
            RP.step!(state,(delta=2.0,))
            ordinary = _ordinary(specs,[10],1,(delta=2.0,))
            @test only(state.statuses).skipped_runs == 1
            @test only(state.statuses).grand_count == 0
            @test only(state.publications).application == :skipped
            @test isequal(_retained_rows(state, specs), _ordinary_rows(ordinary))
        end

        @testset "scientific contract values remain part of admission" begin
            source = ModelSpec(ContractSource(:m); name=:contract_source,
                on=Many(kind=:organ), every=Day(1))
            consumer = ModelSpec(ContractConsumer(:m); name=:contract_consumer,
                on=Many(kind=:organ), every=Day(1))
            mismatch = ModelSpec(ContractConsumer(:cm); name=:contract_consumer,
                on=Many(kind=:organ), every=Day(1))
            @test typeof(consumer.model) === typeof(mismatch.model)
            @test typeof(PSE.variable_contracts_(consumer.model)) === typeof(PSE.variable_contracts_(mismatch.model))
            @test_throws Exception RP.prepare((source, mismatch))
            program = RP.prepare((source, consumer))
            @test RP.instantiate(program, (source.model, consumer.model), [10], [:organ]).program === program
            @test_throws ArgumentError RP.instantiate(program,
                (source.model, mismatch.model), [10], [:organ])
            @test_throws ArgumentError RP.instantiate(program,
                (ContractSource(:cm), consumer.model), [10], [:organ])
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
