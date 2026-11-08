module AuthoredPortInventoryChecks
using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine
const hook_zero = (inputs=0, outputs=0, environment_inputs=0, environment_outputs=0, contracts=0)
PSE.@process "authored_port_inventory" verbose=false
PSE.@process "authored_port_bad_input" verbose=false
PSE.@process "authored_port_source" verbose=false
PSE.@process "authored_port_ordered" verbose=false

function count_hook!(counter, name)
    counter[] = merge(counter[], NamedTuple{(name,)}((getproperty(counter[], name) + 1,)))
    return nothing
end
struct Probe{C,S} <: AbstractAuthored_Port_InventoryModel
    key::Symbol
    counter::C
    seed::S
end
input_name(model::Probe) = Symbol(:buffer_, model.key)
output_name(model::Probe) = Symbol(:seen_, model.key)
distributed_name(model::Probe) = Symbol(:payload_, model.key)
environment_input_name(model::Probe) = Symbol(:T_, model.key)
environment_output_name(model::Probe) = Symbol(:flux_, model.key)
function PSE.inputs_(model::Probe)
    count_hook!(model.counter, :inputs)
    return NamedTuple{(input_name(model),)}((Default(fill(model.seed[], 2)),))
end
function PSE.outputs_(model::Probe)
    count_hook!(model.counter, :outputs)
    return NamedTuple{(output_name(model), distributed_name(model))}((
        0f0, Distributed(Default(fill(model.seed[], 3))),
    ))
end
function PSE.environment_inputs_(model::Probe)
    count_hook!(model.counter, :environment_inputs)
    return NamedTuple{(environment_input_name(model),)}((0f0,))
end
function PSE.environment_outputs_(model::Probe)
    count_hook!(model.counter, :environment_outputs)
    return NamedTuple{(environment_output_name(model),)}((0f0,))
end
function PSE.variable_contracts_(model::Probe)
    count_hook!(model.counter, :contracts)
    names = (input_name(model), output_name(model), distributed_name(model),
        environment_input_name(model), environment_output_name(model))
    return NamedTuple{names}(ntuple(_ -> VariableContract(unit=:probe), length(names)))
end
function PSE.run!(model::Probe, status, environment, constants, context)
    value = sum(getproperty(status, input_name(model))) + getproperty(environment, environment_input_name(model))
    setproperty!(status, output_name(model), value)
    return nothing
end
spec(model::Probe) = ModelSpec(model; name=model.key, on=Many(kind=model.key, scale=:Leaf),
    outputs_to=(OutputTo(One(Self())),))

function inventory_is_value_free(value)
    value isa Union{Nothing,Symbol,VariableContract} && return true
    value isa Tuple && return all(inventory_is_value_free, value)
    value isa NamedTuple && return all(inventory_is_value_free, values(value))
    value isa Union{Default,Required,Distributed,AbstractArray,Ref,AbstractModel} && return false
    parentmodule(typeof(value)) === PSE || return false
    return all(name -> inventory_is_value_free(getfield(value, name)), fieldnames(typeof(value)))
end

@testset "constructor owns one instance-specific value-free port inventory" begin
    a = Probe(:a, Ref(hook_zero), Ref(1f0))
    b = Probe(:b, Ref(hook_zero), Ref(2f0))
    @test typeof(a) === typeof(b)
    model = CompositeModel(Object(:a1; scale=:Leaf, kind=:a), Object(:b1; scale=:Leaf, kind=:b);
        applications=(spec(a), spec(b)), environment=(T_a=1f0, T_b=2f0,
            flux_a=0f0, flux_b=0f0, duration=Hour(1)))
    expected = map(_ -> 1, hook_zero)
    @test a.counter[] == expected
    @test b.counter[] == expected
    recipes = model.scenario_plan_cache.authored
    for (recipe, process_model) in zip(recipes, (a, b))
        has_inventory = hasproperty(recipe, :ports)
        @test has_inventory
        if has_inventory
            ports = recipe.ports
            @test (@inferred PSE._authored_port_names(ports.inputs)) === (input_name(process_model),)
            @test ports.input_names === (input_name(process_model),)
            @test ports.outputs.all_names === (output_name(process_model), distributed_name(process_model))
            @test ports.outputs.local_names === (output_name(process_model),)
            @test ports.outputs.distributed_names === (distributed_name(process_model),)
            @test ports.outputs.canonical_names === ports.outputs.local_names
            @test ports.environment_input_names === (environment_input_name(process_model),)
            @test ports.environment_output_names === (environment_output_name(process_model),)
            @test keys(ports.contracts) == (input_name(process_model), output_name(process_model),
                distributed_name(process_model), environment_input_name(process_model),
                environment_output_name(process_model))
            @test inventory_is_value_free(ports)
        end
    end
    # Compiler-only preparation must not replay any metadata getter.
    before_a, before_b = a.counter[], b.counter[]
    applications = PSE._compile_model_applications(model, model.applications, PSE._model_timeline(model))
    destinations = PSE._resolve_model_output_destination_plans(model, PSE._scenario_preparation(model), applications)
    PSE._resolve_model_input_plans(model, PSE._scenario_preparation(model), applications, destinations)
    PSE._compile_environment_application_plans(model, applications,
        PSE._applications_by_id(applications); prepare_runtime=false)
    @test a.counter[] == before_a
    @test b.counter[] == before_b
    if all(recipe -> hasproperty(recipe, :ports), recipes)
        @test identity(applications[1].plan.ports === recipes[1].ports)
        @test identity(applications[2].plan.ports === recipes[2].ports)
    end

    a.seed[], b.seed[] = 7f0, 9f0
    simulation = run!(model; outputs=:all)
    state_a, state_b = model_status(model, :a1), model_status(model, :b1)
    @test state_a.buffer_a == fill(7f0, 2)
    @test state_b.buffer_b == fill(9f0, 2)
    @test state_a.payload_a == fill(7f0, 3)
    @test state_b.payload_b == fill(9f0, 3)
    @test state_a.seen_a === 15f0
    @test state_b.seen_b === 20f0
    @test a.counter[].inputs > before_a.inputs
    @test a.counter[].outputs > before_a.outputs
    @test a.counter[].environment_inputs == before_a.environment_inputs
    @test a.counter[].environment_outputs == before_a.environment_outputs
    @test a.counter[].contracts == before_a.contracts
    a.seed[] = 11f0
    register_object!(model, Object(:a2; scale=:Leaf, kind=:a))
    step!(simulation)
    newborn = model_status(model, :a2)
    @test newborn.buffer_a == fill(11f0, 2)
    @test newborn.payload_a == fill(11f0, 3)
    @test identity(newborn.buffer_a !== state_a.buffer_a)
    @test identity(newborn.payload_a !== state_a.payload_a)
    @test newborn.seen_a === 23f0
    @test state_a.buffer_a == fill(7f0, 2)
    @test state_a.payload_a == fill(7f0, 3)
    before_ordinary_a, before_ordinary_b = a.counter[], b.counter[]
    step!(simulation)
    @test a.counter[] == before_ordinary_a
    @test b.counter[] == before_ordinary_b
    @test outputs(simulation)[(:a, ObjectId(:a1), :seen_a)] == [(1.0, 15f0), (2.0, 15f0), (3.0, 15f0)]
    @test outputs(simulation)[(:a, ObjectId(:a2), :seen_a)] == [(2.0, 23f0), (3.0, 23f0)]
    previous_contracts = a.counter[].contracts
    previous_environment = a.counter[].environment_inputs
    current = Advanced.refresh_bindings!(model; force=true)
    @test identity(only(app for app in current.applications if app.id === :a).plan.ports !== recipes[1].ports)
    @test a.counter[].contracts == previous_contracts + 1
    @test a.counter[].environment_inputs == previous_environment + 1
    step!(simulation)
    @test identity(simulation.compiled === current)
    @test a.counter[].contracts == previous_contracts + 1
    @test a.counter[].environment_inputs == previous_environment + 1
    @test state_a.buffer_a == fill(7f0, 2)
    @test newborn.buffer_a == fill(11f0, 2)
    @test outputs(simulation)[(:a, ObjectId(:a1), :seen_a)] ==
          [(1.0, 15f0), (2.0, 15f0), (3.0, 15f0), (4.0, 15f0)]
end

const broken_input_calls = Ref(0)
struct BrokenInput{T} <: AbstractAuthored_Port_Bad_InputModel
    token::T
end
function PSE.inputs_(::BrokenInput)
    broken_input_calls[] += 1
    error("captured input declaration failure")
end
PSE.outputs_(::BrokenInput) = (bad_seen=0f0,)
PSE.run!(::BrokenInput, status, environment, constants, context) = nothing

@testset "failed input metadata is frozen without hiding valid target applications" begin
    broken_input_calls[] = 0
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(BrokenInput(:application); name=:broken, on=One(id=:leaf)),))
    @test broken_input_calls[] == 1
    @test isnothing(model.scenario_plan_cache.failure)
    @test hasproperty(only(model.scenario_plan_cache.authored), :ports)
    for _ in 1:2
        report = PSE.compile_model_report(model)
        @test [app.id for app in report.applications] == [:broken]
        @test any(diagnostic -> occursin("captured input declaration failure", diagnostic.message), report.diagnostics)
        @test broken_input_calls[] == 1
        @test_throws "captured input declaration failure" run!(model; steps=0)
        @test broken_input_calls[] == 1
    end
    view = try
        PSE.GraphEditor.model_graph_view(model)
    catch error
        @info "failed port graph inspection" error=sprint(showerror, error)
        nothing
    end
    @test !isnothing(view)
    if !isnothing(view)
        @test only(view.applications)["applicationId"] == "broken"
        @test !isempty(view.diagnostics)
    end
    @test broken_input_calls[] == 1
    @test isnothing(model_status(model, :leaf))
end

@testset "live application Scope is repaired before a saved input failure is delivered" begin
    broken_input_calls[] = 0
    model = CompositeModel(Object(:scene; scale=:Scene); applications=(
        ModelSpec(BrokenInput(:application); name=:broken,
            on=One(Scope(ObjectId(:future_root)); scale=:Leaf)),))
    @test broken_input_calls[] == 1
    @test isnothing(model.scenario_plan_cache.failure)
    @test_throws "No instance or object ID" run!(model; steps=0)
    @test broken_input_calls[] == 1
    register_object!(model, Object(:future_root; scale=:Plant))
    register_object!(model, Object(:future_leaf; scale=:Leaf, parent=:future_root))
    @test_throws "captured input declaration failure" run!(model; steps=0)
    @test broken_input_calls[] == 1
    @test isnothing(model_status(model, :future_leaf))
end

struct Source{UNIT} <: AbstractAuthored_Port_SourceModel end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(::Source) = (value=0f0,)
PSE.variable_contracts_(::Source{UNIT}) where {UNIT} = (value=VariableContract(unit=UNIT),)
PSE.run!(::Source, status, environment, constants, context) = nothing
struct Ordered{C} <: AbstractAuthored_Port_OrderedModel
    contracts::C
end
PSE.inputs_(::Ordered) = (first=Required(Float32), second=Required(Float32))
PSE.outputs_(::Ordered) = (seen=0f0,)
function PSE.variable_contracts_(model::Ordered)
    model.contracts[] += 1
    return (first=VariableContract(unit=:first), second=VariableContract(unit=:wrong))
end
PSE.run!(::Ordered, status, environment, constants, context) = nothing

@testset "earlier live route scope still wins over a later pure contract error" begin
    calls = Ref(0)
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(Source{:first}(); name=:first_source, on=Many(scale=:FirstSource)),
        ModelSpec(Source{:second}(); name=:second_source, on=Many(scale=:SecondSource)),
        ModelSpec(Ordered(calls); name=:reader, on=One(id=:leaf), inputs=(
            first=One(Scope(ObjectId(:future)); application=:first_source, var=:value),
            second=One(application=:second_source, var=:value),
        )),
    ))
    @test calls[] == 1
    @test_throws "No instance or object ID" run!(model; steps=0)
    @test calls[] == 1
    register_object!(model, Object(:future; scale=:Plant))
    @test_throws "Incompatible variable contracts for input `second`" run!(model; steps=0)
    @test calls[] == 1
    @test isnothing(model_status(model, :leaf))
end
PSE.@process "authored_port_bad_environment" verbose=false
struct BrokenEnvironment{WHICH} <: AbstractAuthored_Port_Bad_EnvironmentModel end
const failed_environment_inputs = Ref(0)
const failed_environment_outputs = Ref(0)
PSE.inputs_(::BrokenEnvironment) = NamedTuple()
PSE.outputs_(::BrokenEnvironment) = (seen=0f0,)
PSE.run!(::BrokenEnvironment, status, environment, constants, context) = nothing
function PSE.environment_inputs_(::BrokenEnvironment{WHICH}) where {WHICH}
    WHICH === :inputs || return NamedTuple()
    failed_environment_inputs[] += 1
    error("captured environment input declaration failure")
end
function PSE.environment_outputs_(::BrokenEnvironment{WHICH}) where {WHICH}
    WHICH === :outputs || return NamedTuple()
    failed_environment_outputs[] += 1
    error("captured environment output declaration failure")
end

@testset "empty remapping defers failed environment metadata without replay" begin
    for which in (:inputs, :outputs)
        failed_environment_inputs[] = failed_environment_outputs[] = 0
        declaration = which === :inputs ? BrokenEnvironment{:inputs}() : BrokenEnvironment{:outputs}()
        counter = which === :inputs ? failed_environment_inputs : failed_environment_outputs
        message = which === :inputs ? "captured environment input declaration failure" :
            "captured environment output declaration failure"
        model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
            ModelSpec(declaration; name=:probe, on=One(id=:leaf),
                environment=Environment(sources=NamedTuple())),))
        @test counter[] == 1
        @test isnothing(model.scenario_plan_cache.failure)
        applications = PSE._compile_model_applications(model, model.applications, PSE._model_timeline(model))
        @test counter[] == 1 # empty remap must not demand failed names early
        destinations = PSE._resolve_model_output_destination_plans(model, PSE._scenario_preparation(model), applications)
        @test_throws message PSE._resolve_model_input_plans(model, PSE._scenario_preparation(model), applications, destinations)
        @test counter[] == 1 # even empty contracts validate all declared port names
        @test_throws message PSE._compile_environment_application_plans(model, applications,
            PSE._applications_by_id(applications); prepare_runtime=false)
        @test counter[] == 1
        @test_throws message run!(model; steps=0)
        @test counter[] == 1
        report = PSE.compile_model_report(model)
        @test [app.id for app in report.applications] == [:probe]
        @test any(diagnostic -> occursin(message, diagnostic.message), report.diagnostics)
        @test counter[] == 1
    end
end

PSE.@process "authored_port_shape_before_names" verbose=false
struct BadShapeBeforeNames <: AbstractAuthored_Port_Shape_Before_NamesModel end
const shape_input_calls = Ref(0)
const shape_contract_calls = Ref(0)
function PSE.inputs_(::BadShapeBeforeNames)
    shape_input_calls[] += 1
    error("input failure must not beat malformed contracts")
end
PSE.outputs_(::BadShapeBeforeNames) = (seen=0f0,)
function PSE.variable_contracts_(::BadShapeBeforeNames)
    shape_contract_calls[] += 1
    return 42
end
PSE.run!(::BadShapeBeforeNames, status, environment, constants, context) = nothing
@testset "contract shape errors keep precedence over saved port failures" begin
    shape_input_calls[] = shape_contract_calls[] = 0
    model = CompositeModel(Object(:leaf; scale=:Leaf); applications=(
        ModelSpec(BadShapeBeforeNames(); name=:probe, on=One(id=:leaf)),))
    @test shape_input_calls[] == shape_contract_calls[] == 1
    @test isnothing(model.scenario_plan_cache.failure)
    @test_throws "must return a NamedTuple" run!(model; steps=0)
    @test shape_input_calls[] == shape_contract_calls[] == 1
    @test isnothing(model_status(model, :leaf))
end

PSE.@process "authored_port_commit" verbose=false
PSE.@process "authored_port_capture" verbose=false
const EA = PSE.EnvironmentAPI
mutable struct CommitBackend{T} <: EA.AbstractEnvironmentBackend
    value::T
    writes::Vector{NamedTuple}
end
EA.base_step_seconds(::CommitBackend) = 3600.0
EA.get_nsteps(::CommitBackend) = 4
EA.environment_variables(::CommitBackend) = Set((:T,))
EA.bind_environment(::CommitBackend, object::PSE.Object, context, config) =
    (application=context.application, sink=isnothing(config) ? nothing : get(config, :sink, nothing))
EA.sample(backend::CommitBackend, handle, ::Symbol, time) = backend.value
function EA.commit_environment!(backend::CommitBackend, handle, state, time)
    handle.sink === :inventory_commit || error("missing inventory commit sink")
    backend.value = state.T
    push!(backend.writes, (application=handle.application, value=state.T, time=Float64(time)))
    return nothing
end
struct CommitProbe{T,Q,F} <: AbstractAuthored_Port_CommitModel
    zero_value::T
    queries::Q
    forbidden::F
end
PSE.inputs_(::CommitProbe) = NamedTuple()
PSE.outputs_(model::CommitProbe) = (seen=model.zero_value, calls=0)
PSE.environment_inputs_(model::CommitProbe) = (T=model.zero_value,)
function PSE.environment_outputs_(model::CommitProbe)
    model.queries[] += 1
    model.forbidden[] && error("environment output metadata was replayed")
    return (T=model.zero_value,)
end
function PSE.run!(::CommitProbe, status, environment, constants, context)
    status.calls += 1
    status.seen = environment.T + one(status.seen)
    commit_environment!(context, (T=status.seen,))
    return nothing
end
struct Capture{C} <: AbstractAuthored_Port_CaptureModel
    capture::C
end
PSE.inputs_(::Capture) = NamedTuple()
PSE.outputs_(::Capture) = (owners=0,)
function PSE.run!(model::Capture, status, environment, constants, context)
    model.capture[] = context
    status.owners += 1
    return nothing
end

@testset "commits use captured names with fresh state in scheduled and evaluated execution" begin
    for T in (Float32, Float64)
        queries, forbidden = Ref(0), Ref(false)
        backend = CommitBackend(zero(T), NamedTuple[])
        probe = ModelSpec(CommitProbe(zero(T), queries, forbidden); name=:probe,
            on=One(id=:leaf), environment=Environment(provider=:inventory_commit, sink=:inventory_commit))
        model = CompositeModel(Object(:leaf); applications=(probe,), environment=backend)
        @test queries[] == 1
        forbidden[] = true
        simulation = run!(model; steps=2, outputs=:all)
        @test queries[] == 1
        @test backend.value === T(2)
        @test [row.value for row in backend.writes] == T[1, 2]
        @test outputs(simulation)[(:probe, ObjectId(:leaf), :seen)] == [(1.0, T(1)), (2.0, T(2))]

        queries, forbidden = Ref(0), Ref(false)
        backend = CommitBackend(zero(T), NamedTuple[])
        capture = Ref{Any}()
        model = CompositeModel(Object(:owner), Object(:leaf; parent=:owner); applications=(
            ModelSpec(Capture(capture); name=:owner, on=One(id=:owner), calls=(
                child=One(SceneScope(); id=:leaf, application=:probe),)),
            ModelSpec(CommitProbe(zero(T), queries, forbidden); name=:probe,
                on=One(id=:leaf), environment=Environment(provider=:inventory_commit, sink=:inventory_commit)),
        ), environment=backend)
        @test queries[] == 1
        forbidden[] = true
        simulation = run!(model; outputs=:all)
        target = only(call_targets(capture[], :child))
        run_call!(target; publish=false)
        @test target.status.calls == 1
        @test isempty(backend.writes)
        @test backend.value === zero(T)
        evaluation = evaluate_call!(target; sampled_environment=(T=T(4),))
        @test target.status.calls == 2
        @test target.status.seen === T(5)
        @test isempty(backend.writes)
        @test identity(accept_call!(evaluation) === evaluation)
        @test target.status.calls == 2 # acceptance never reruns its kernel
        @test backend.value === T(5)
        @test [row.value for row in backend.writes] == T[5]
        run_call!(target; publish=true)
        @test target.status.calls == 3
        @test backend.value === T(6)
        @test [row.value for row in backend.writes] == T[5, 6]
        run_call!(target; publish=false)
        @test target.status.calls == 4
        @test target.status.seen === T(7)
        @test backend.value === T(6)
        @test length(backend.writes) == 2
        @test queries[] == 1
        @test outputs(simulation)[(:probe, ObjectId(:leaf), :seen)] == [(1.0, T(6))]
    end
end

PSE.@process "authored_port_native_metadata" verbose=false
struct NativeMetadataProbe{HAS_OUTPUT} <: AbstractAuthored_Port_Native_MetadataModel end
const native_metadata_queries = Ref(0)
const native_metadata_forbidden = Ref(false)
PSE.inputs_(::NativeMetadataProbe) = NamedTuple()
PSE.outputs_(::NativeMetadataProbe) = (seen=0f0,)
function PSE.environment_outputs_(::NativeMetadataProbe{HAS_OUTPUT}) where {HAS_OUTPUT}
    native_metadata_queries[] += 1
    native_metadata_forbidden[] && error("native metadata was replayed")
    return HAS_OUTPUT ? (T=0f0,) : NamedTuple()
end
PSE.run!(::NativeMetadataProbe, status, environment, constants, context) = (status.seen += 1f0; nothing)
@testset "public compilation admission consumes the same authored environment names" begin
    for has_output in (false, true)
        native_metadata_queries[] = 0
        native_metadata_forbidden[] = false
        process_model = has_output ? NativeMetadataProbe{true}() : NativeMetadataProbe{false}()
        model = CompositeModel(Object(:leaf); applications=(
            ModelSpec(process_model; name=:probe, on=One(id=:leaf)),),
            environment=(duration=Hour(1),))
        @test native_metadata_queries[] == 1
        native_metadata_forbidden[] = true
        if has_output
            rejection = try
                PSE.Compilation.prepare(model)
                nothing
            catch error
                error
            end
            @test rejection isa ArgumentError
            message = rejection isa Exception ? sprint(showerror, rejection) : "accepted"
            @test occursin("application :probe", message)
            @test occursin("environment outputs are unsupported", message)
        else
            program = PSE.Compilation.prepare(model)
            continue!(program; steps=2)
            @test final_state(program).seen === 2f0
        end
        @test native_metadata_queries[] == 1
        @test isnothing(model_status(model, :leaf))
    end
end

module CapturedPreparationErrorIdentityChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine

mutable struct TaggedHookError <: Exception
    marker::Symbol
end
Base.showerror(io::IO, error::TaggedHookError) = print(io, "saved hook error: ", error.marker)

@testset "saved declaration errors keep identity and original traces" begin
    for error in (ErrorException("saved declaration"),
        MethodError(identity, (1, 2)), TaggedHookError(:original))
        calls = Ref(0)
        failure = PSE._capture_authored_metadata(:input_ports, :identity) do
            calls[] += 1
            throw(error)
        end
        original_backtrace = failure.backtrace
        original_frames = copy(original_backtrace)
        message = sprint(showerror, error)
        @test calls[] == 1
        @test !isempty(original_backtrace)
        for reader in (PSE._authored_port_names, PSE._authored_metadata_value), _ in 1:2
            caught = try
                reader(failure)
                nothing
            catch exception
                exception
            end
            @test caught === error
            @test sprint(showerror, caught) == message
            @test failure.error === error
            @test failure.backtrace === original_backtrace
            @test failure.backtrace == original_frames
            @test (failure.phase, failure.application_id) == (:input_ports, :identity)
            @test calls[] == 1
        end
        copied = deepcopy(failure)
        @test copied.error === error
        @test copied.backtrace !== original_backtrace
        @test copied.backtrace == original_frames
        @test calls[] == 1
    end
end
end

end
