module AuthoredInputGraphChecks
using Dates, DataFrames, PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "authored_graph_source" verbose=false
PSE.@process "authored_graph_sink" verbose=false
PSE.@process "authored_graph_writer" verbose=false
PSE.@process "authored_graph_update" verbose=false
PSE.@process "authored_graph_child" verbose=false
PSE.@process "authored_graph_owner" verbose=false
PSE.@process "authored_graph_consumer" verbose=false
PSE.@process "authored_graph_previous" verbose=false
PSE.@process "authored_graph_broken" verbose=false

struct Source{C,Q} <: AbstractAuthored_Graph_SourceModel
    runs::C
    declarations::Q
end
Source(runs) = Source(runs, Ref(0))
PSE.inputs_(::Source) = NamedTuple()
function PSE.outputs_(model::Source)
    model.declarations[] += 1
    return (value=0f0,)
end
function PSE.run!(model::Source, status, environment, constants, context)
    model.runs[] += 1
    status.value += 1f0
    return nothing
end
struct Sink <: AbstractAuthored_Graph_SinkModel end
PSE.inputs_(::Sink) = (value=Required(Float32),)
PSE.outputs_(::Sink) = (seen=0f0,)
PSE.run!(::Sink, status, environment, constants, context) = (status.seen = status.value; nothing)

function authored_program(model)
    preparation = model.scenario_plan_cache
    @test preparation isa PSE.ScenarioPreparation
    ready = hasproperty(preparation, :program)
    @test ready
    return ready ? preparation.program : nothing
end

@testset "constructor prepares complete explicit and inferred dependencies before weather or objects" begin
    for explicit in (false, true)
        weather = DataFrame(duration=Hour[])
        runs = Ref(0)
        source = Source(runs)
        target = Many(Scope(ObjectId(:future_root)); scale=:Leaf)
        model = CompositeModel(Object(:scene; scale=:Scene); environment=weather,
            applications=(
                ModelSpec(Sink(); name=:sink, on=target,
                    inputs=explicit ? (value=One(Self(); application=:source),) : NamedTuple()),
                ModelSpec(source; name=:source, on=target),
            ))
        preparation = model.scenario_plan_cache
        program = authored_program(model)
        @test isempty(weather)
        @test runs[] == 0
        @test source.declarations[] == 1
        @test model.binding_cache === nothing
        @test preparation.resolved === nothing
        @test model_status(model, :scene) === nothing
        if !isnothing(program)
            route = only(program.input_records)
            @test route isa PSE.CompiledModelInputPlan
            @test route.application_id === :sink
            @test route.origin === (explicit ? :model_spec : :inferred_same_object)
            @test route.potential_source_application_ids === (:source,)
            @test program.graph.application_children.source === (:sink,)
            @test program.graph.application_order === (:source, :sink)
            @test isempty(program.graph.manual_application_ids)
        end
        # Physical roots, membership, weather duration and history dimensions
        # are supplied only after the constructor has prepared the graph.
        register_object!(model, Object(:future_root; scale=:Plant, parent=:scene))
        register_object!(model, Object(:a; scale=:Leaf, parent=:future_root))
        append!(weather, DataFrame(duration=fill(Hour(1), 3)))
        simulation = run!(model; steps=2, outputs=:all)
        if !isnothing(program)
            plan = simulation.compiled.scenario_plan
            @test PSE._resolved_scenario_graph(preparation, simulation.compiled.applications,
                plan.input_plans, plan.call_plans, plan.distributed_output_plans) === program.graph
        end
        @test source.declarations[] > 1 # real status initialization remains fresh
        @test model_status(model, :a).seen === 2f0
        @test runs[] == 2
        register_object!(model, Object(:b; scale=:Leaf, parent=:future_root))
        step!(simulation)
        @test runs[] == 4
        @test model_status(model, :a).seen === 3f0
        @test model_status(model, :b).seen === 1f0
        @test outputs(simulation)[(:sink, ObjectId(:a), :seen)] == [(1.0, 1f0), (2.0, 2f0), (3.0, 3f0)]
        @test outputs(simulation)[(:sink, ObjectId(:b), :seen)] == [(3.0, 1f0)]
        @test model.scenario_plan_cache === preparation
        if !isnothing(program)
            @test model.scenario_plan_cache.program === program
        end
    end
end

struct Writer <: AbstractAuthored_Graph_WriterModel end
PSE.inputs_(::Writer) = NamedTuple()
PSE.outputs_(::Writer) = (signal=Distributed(Default(0f0)),)
function PSE.run!(::Writer, status, environment, constants, context)
    targets = output_targets(context, (:signal,))
    for index in eachindex(targets.columns.signal)
        targets.columns.signal[index] = 2f0
    end
    return nothing
end
struct Updater <: AbstractAuthored_Graph_UpdateModel end
PSE.inputs_(::Updater) = NamedTuple()
PSE.outputs_(::Updater) = (signal=0f0,)
PSE.run!(::Updater, status, environment, constants, context) = (status.signal += 1f0; nothing)
struct Child <: AbstractAuthored_Graph_ChildModel end
PSE.inputs_(::Child) = NamedTuple()
PSE.outputs_(::Child) = (manual_value=0f0, manual_calls=0)
function PSE.run!(::Child, status, environment, constants, context)
    status.manual_value += 2f0
    status.manual_calls += 1
    return nothing
end
struct Owner <: AbstractAuthored_Graph_OwnerModel end
PSE.inputs_(::Owner) = NamedTuple()
PSE.outputs_(::Owner) = (manual_seen=0f0,)
function PSE.run!(::Owner, status, environment, constants, context)
    child = only(run_call!(context, :child; publish=true))
    status.manual_seen = child.status.manual_value
    return nothing
end
struct Consumer <: AbstractAuthored_Graph_ConsumerModel end
PSE.inputs_(::Consumer) = (signal=Required(Float32), manual_value=Required(Float32))
PSE.outputs_(::Consumer) = (total=0f0,)
PSE.run!(::Consumer, status, environment, constants, context) = (status.total = status.signal + status.manual_value; nothing)
struct Previous <: AbstractAuthored_Graph_PreviousModel end
PSE.inputs_(::Previous) = (lagged=Required(Float32),)
PSE.outputs_(::Previous) = (previous=0f0,)
PSE.run!(::Previous, status, environment, constants, context) = (status.previous = status.lagged; nothing)

@testset "one authored graph contains distributed writes Updates manual ownership and PreviousTimeStep" begin
    weather = DataFrame(duration=Hour[])
    model = CompositeModel(Object(:scene; scale=:Scene); environment=weather,
        applications=(
            ModelSpec(Consumer(); name=:consumer, on=Many(scale=:Leaf)),
            ModelSpec(Previous(); name=:previous, on=Many(scale=:Leaf),
                inputs=(PreviousTimeStep(:lagged) => One(Self(); application=:updater, var=:signal),)),
            ModelSpec(Writer(); name=:writer, on=One(id=:scene),
                outputs_to=(OutputTo(Many(scale=:Leaf, within=SceneScope())),)),
            ModelSpec(Updater(); name=:updater, on=Many(scale=:Leaf), updates=Updates(:signal; after=:writer)),
            ModelSpec(Owner(); name=:owner, on=One(id=:scene),
                calls=(child=One(id=:leaf, application=:child, within=SceneScope()),)),
            ModelSpec(Child(); name=:child, on=Many(scale=:Leaf)),
        ))
    program = authored_program(model)
    @test model_status(model, :scene) === nothing
    @test model.binding_cache === nothing
    @test model.scenario_plan_cache.resolved === nothing
    if !isnothing(program)
        destination = only(program.output_records[:writer])
        @test destination.variable_names === (:signal,)
        @test !hasproperty(destination, :declarations)
        @test program.graph.manual_application_ids === (:child,)
        children = program.graph.application_children
        @test :updater in children.writer
        @test :consumer in children.updater
        @test :consumer in children.owner
        @test !(:previous in children.updater)
        previous = only(filter(route -> route.application_id === :previous, program.input_records))
        @test previous.breaks_same_step_cycle
        @test previous.potential_source_application_ids === (:updater,)
    end
    register_object!(model, Object(:leaf; scale=:Leaf, parent=:scene,
        status=Status(signal=10f0, lagged=10f0)))
    append!(weather, DataFrame(duration=fill(Hour(1), 2)))
    simulation = run!(model; steps=2, outputs=:all)
    state = model_status(model, :leaf)
    @test state.signal === 3f0
    @test state.manual_value === 4f0
    @test state.manual_calls == 2
    @test state.total === 7f0
    @test state.previous === 3f0
    @test outputs(simulation)[(:consumer, ObjectId(:leaf), :total)] == [(1.0, 5f0), (2.0, 7f0)]
    @test outputs(simulation)[(:previous, ObjectId(:leaf), :previous)] == [(1.0, 10f0), (2.0, 3f0)]
    @test outputs(simulation)[(:child, ObjectId(:leaf), :manual_value)] == [(1.0, 2f0), (2.0, 4f0)]
    if !isnothing(program)
        @test model.scenario_plan_cache.program === program
    end
end

struct Broken <: AbstractAuthored_Graph_BrokenModel
    token::Symbol
end
PSE.outputs_(::Broken) = error("authored graph deliberately invalid output")

@testset "filtered diagnostics project the same authored input factory without renumbering slots" begin
    source = Source(Ref(0))
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(source; name=:source, on=One(id=:leaf)),
        ModelSpec(Broken(:once); name=:broken, on=One(id=:leaf)),
        ModelSpec(Sink(); name=:sink, on=One(id=:leaf),
            inputs=(value=One(Self(); application=:source),)),
    ))
    program = authored_program(model)
    report = PSE.compile_model_report(model)
    @test [app.id for app in report.applications] == [:source, :sink]
    @test [app.slot for app in report.applications] == [1, 3]
    @test any(diagnostic -> occursin("deliberately invalid output", diagnostic.message), report.diagnostics)
    @test !any(diagnostic -> occursin("BoundsError", diagnostic.message), report.diagnostics)
    @test length(report.input_bindings) == 1
    @test only(report.input_bindings).application_id === :sink
    @test only(report.input_bindings).source_application_ids == [:source]
    @test model_status(model, :leaf) === nothing
    @test source.runs[] == 0
    if !isnothing(program)
        @test model.scenario_plan_cache.program === program
    end
end

PSE.@process "authored_graph_contract_source" verbose=false
PSE.@process "authored_graph_contract_sink" verbose=false
struct ContractSource{UNIT} <: AbstractAuthored_Graph_Contract_SourceModel end
PSE.inputs_(::ContractSource) = NamedTuple()
PSE.outputs_(::ContractSource) = (value=0f0,)
PSE.variable_contracts_(::ContractSource{UNIT}) where {UNIT} = (value=VariableContract(unit=UNIT),)
PSE.run!(::ContractSource, status, environment, constants, context) = nothing
struct OrderedSink{C} <: AbstractAuthored_Graph_Contract_SinkModel
    declarations::C
end
PSE.inputs_(::OrderedSink) = (first=Required(Float32), second=Required(Float32))
PSE.outputs_(::OrderedSink) = (seen=0f0,)
function PSE.variable_contracts_(model::OrderedSink)
    model.declarations[] += 1
    return (first=VariableContract(unit=:first), second=VariableContract(unit=:wrong))
end
PSE.run!(::OrderedSink, status, environment, constants, context) = nothing

@testset "saved route failures retain physical Scope error order" begin
    calls = Ref(0)
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(ContractSource{:first}(); name=:first, on=Many(scale=:First)),
        ModelSpec(ContractSource{:second}(); name=:second, on=Many(scale=:Second)),
        ModelSpec(OrderedSink(calls); name=:sink, on=One(id=:leaf), inputs=(
            first=One(Scope(ObjectId(:future)); application=:first, var=:value),
            second=One(application=:second, var=:value),
        )),
    ))
    program = authored_program(model)
    @test calls[] == 1
    if !isnothing(program)
        @test length(program.input_records) == 2
        @test first(program.input_records) isa PSE.CompiledModelInputPlan
        @test last(program.input_records) isa PSE.ScenarioPreparationFailure
        @test last(program.input_records).application_id === :sink
    end
    @test_throws "No instance or object ID" run!(model; steps=0)
    @test calls[] == 1
    register_object!(model, Object(:future; scale=:Plant))
    @test_throws "Incompatible variable contracts for input `second`" run!(model; steps=0)
    @test calls[] == 1
    @test model_status(model, :leaf) === nothing
end

@testset "earlier output Scope wins over a later captured output partition error" begin
    model = CompositeModel(Object(:scene; scale=:Scene); applications=(
        ModelSpec(Writer(); name=:first, on=One(id=:scene),
            outputs_to=(OutputTo(Many(Scope(ObjectId(:future)); scale=:Leaf)),)),
        ModelSpec(Writer(); name=:second, on=One(id=:scene),
            outputs_to=(OutputTo(Many(scale=:Leaf); vars=(:unknown,)),)),
    ))
    program = authored_program(model)
    if !isnothing(program)
        @test only(program.output_records[:first]) isa PSE.CompiledModelOutputDestinationPlan
        @test program.output_records[:second] isa PSE.ScenarioPreparationFailure
    end
    @test_throws "No instance or object ID" run!(model; steps=0)
    register_object!(model, Object(:future; scale=:Plant))
    @test_throws "not declared as a Distributed output" run!(model; steps=0)
    @test model_status(model, :scene) === nothing
end

struct ContractSink <: AbstractAuthored_Graph_SinkModel end
PSE.inputs_(::ContractSink) = (value=Default(7f0),)
PSE.outputs_(::ContractSink) = (seen=0f0,)
PSE.variable_contracts_(::ContractSink) = (value=VariableContract(unit=:sink),)
PSE.run!(::ContractSink, status, environment, constants, context) = (status.seen=status.value; nothing)

@testset "a removed diagnostic producer cannot leave a captured endpoint mismatch behind" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(ContractSource{:wrong}(); name=:source,
            on=One(Scope(ObjectId(:missing)); scale=:Leaf)),
        ModelSpec(Broken(:keep_slots); name=:broken, on=One(id=:leaf)),
        ModelSpec(ContractSink(); name=:sink, on=One(id=:leaf),
            inputs=(value=OptionalOne(Self(); application=:source),)),
    ))
    program = authored_program(model)
    if !isnothing(program)
        @test any(record -> record isa PSE.ScenarioPreparationFailure &&
            occursin("Incompatible variable contracts", sprint(showerror, record.error)), program.input_records)
    end
    report = PSE.compile_model_report(model)
    @test [app.id for app in report.applications] == [:sink]
    @test only(report.applications).slot == 3
    @test any(diagnostic -> occursin("No instance or object ID", diagnostic.message), report.diagnostics)
    @test !any(diagnostic -> occursin("Incompatible variable contracts", diagnostic.message), report.diagnostics)
    @test !any(diagnostic -> occursin("BoundsError", diagnostic.message), report.diagnostics)
    @test model_status(model, :leaf) === nothing
end

end
