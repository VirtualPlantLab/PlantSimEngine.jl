# Included in NativePBDriver. These are runtime/publication checks, not new
# biological kernels; all CR controllers retain their original methods.
for T in (CR.GateCallController, CR.GateCallWorker, CR.GateStaleController,
    CR.GateOverrideController, CR.CallExceptionController, CR.CallExceptionWorker)
    @eval native_call_effects(::Type{$T}) = :fixed_native_calls
end

include("pb_reference_escape_checks.jl")

function _native_gate_copy(model)
    objects = [PSE.Object(object.id; scale=object.scale, kind=object.kind,
        species=object.species, name=object.name, parent=object.parent,
        geometry=object.geometry,
        status=object.status === nothing ? (;) : NamedTuple(object.status))
        for object in PSE.model_objects(model)]
    return PSE.CompositeModel(objects...; applications=model.applications,
        environment=model.environment, status_storage=PSE.NativeColumnStorage())
end

PSE.@process "native_selected_call_controller" verbose=false
struct NativeSelectedCallController <: AbstractNative_Selected_Call_ControllerModel end
PSE.inputs_(::NativeSelectedCallController) = (;)
PSE.outputs_(::NativeSelectedCallController) = (observed=0.0,)
function PSE.run!(::NativeSelectedCallController, status, environment, constants, context)
    targets = PSE.run_call!(context, :worker; objects=[:worker],
        sampled_environment=CR.GateSampledRow(6.0), publish=true)
    status.observed = only(targets).status.value
    return nothing
end
native_call_effects(::Type{NativeSelectedCallController}) = :fixed_native_calls

"""Exact mutable-state/history gates for delegated public hard-call semantics."""
function native_call_semantics_checks()
    reports = NamedTuple[]
    cases = (
        (name=:accepted_evaluation, builder=() -> CR.gate_call_fixture()),
        (name=:stale_token, builder=() -> CR.gate_call_fixture(CR.GateStaleController())),
        (name=:environment_override, builder=() -> CR.gate_call_fixture(CR.GateOverrideController())),
        (name=:selected_objects, builder=() -> CR.gate_call_fixture(NativeSelectedCallController())),
        (name=:published_exception, builder=() -> CR.call_exception_fixture(; publish=true)),
        (name=:unpublished_exception, builder=() -> CR.call_exception_fixture(; publish=false)),
    )
    @testset "Native fixed-call delegated API and cache cleanup" begin
        for case in cases
            reference = PSE.run!(case.builder(); steps=0, outputs=:all)
            simulation = PSE.run!(_native_gate_copy(case.builder()); steps=0, outputs=:all)
            program = compile_native_call_driver(simulation)
            @test native_call_driver_report(program).native_root_memberships > 0
            PSE.continue!(reference; steps=1)
            advance_native_call_driver!(program; steps=1)
            @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
            # Ordinary execution must see exactly the same released call caches
            # and accepted output state after the numerical backend stops.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
            for node in program.nodes, batch in node.batches
                batch isa NativeRootBatch || continue
                @test !batch.lease.running
                function leases_released(context)
                    all(values(context.calls.entries)) do entry
                        !entry.plan.cache.in_use && leases_released(entry.plan.context)
                    end
                end
                @test all(row -> leases_released(row.context), batch.rows)
            end
            report = native_call_driver_report(program)
            @test report.executed_numerical_roots > 0
            if case.name in (:environment_override, :selected_objects)
                @test report.fallback_calls > 0
            else
                @test report.executed_numerical_calls > 0
            end
            push!(reports, (case=case.name, report))
        end

        # No ordinary reference cell is silently copied into a supposed native
        # region. The same typed call graph is independently usable with the
        # exact ordinary Status representation in the reference-driver arm.
        ordinary = PSE.run!(CR.pb_many_fixture(; nobjects=2, steps=1); steps=0, outputs=:all)
        rejected = compile_native_call_driver(ordinary; state_strategy=:native)
        @test native_call_driver_report(rejected).native_root_memberships == 0
        reference_driver = compile_native_call_driver(ordinary; state_strategy=:references)
        advance_native_call_driver!(reference_driver; steps=1)
        report = native_call_driver_report(reference_driver)
        @test report.executed_numerical_roots == 2
        @test report.executed_numerical_calls > 0
        @test report.executed_native_column_fields == 0
        control = PSE.run!(CR.pb_many_fixture(; nobjects=2, steps=1); steps=1, outputs=:all)
        @test isequal(CR.downstream_fingerprint(ordinary), CR.downstream_fingerprint(control))
        push!(reports, (case=:reference_driver_no_native_copy, report))

        # An unaudited/multiple-target controller preserves its original path.
        control = PSE.run!(CR.gate_many_fixture(2); steps=1, outputs=:all)
        simulation = PSE.run!(_native_gate_copy(CR.gate_many_fixture(2)); steps=0, outputs=:all)
        program = compile_native_call_driver(simulation)
        @test native_call_driver_report(program).native_root_memberships == 0
        advance_native_call_driver!(program; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(control))
        @test native_call_driver_report(program).ordinary_batch_executions > 0
        push!(reports, (case=:unsupported_graph_fallback, report=native_call_driver_report(program)))
    end
    return (; passed=true, cases=length(reports), reports)
end

"""Real PB: alternate optimized/public continuation, live edits and removal."""
function pb_native_continuation_checks(; nobjects::Int=4)
    nobjects >= 2 || throw(ArgumentError("Removal gate requires at least two objects"))
    reference_model = CR.pb_many_fixture(; nobjects, steps=4)
    reference = PSE.run!(reference_model; steps=0, outputs=:all)
    fixture = pb_native_fixture(; nobjects, steps=4)
    simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
    original = PSE.model_status(fixture.model, 1)
    escaped = PSE.refvalue(original, :Ra_SW_f)
    program = compile_native_call_driver(simulation)
    @testset "Real PB native/public continuation and live reference" begin
        PSE.continue!(reference; steps=1)
        advance_native_call_driver!(program; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        PSE.continue!(reference; steps=1)
        PSE.continue!(simulation; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        escaped[] = 177.0
        PSE.model_status(reference_model, 1).Ra_SW_f = 177.0
        PSE.continue!(reference; steps=1)
        advance_native_call_driver!(program; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        PSE.remove_object!(fixture.model, 2)
        PSE.remove_object!(reference_model, 2)
        PSE.continue!(reference; steps=1)
        advance_native_call_driver!(program; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        @test original === PSE.model_status(fixture.model, 1)
        @test escaped === PSE.refvalue(original, :Ra_SW_f)
        @test escaped[] == 177.0
        @test native_call_driver_report(program).rebuilds > 0
        @test native_call_driver_report(program).executed_numerical_calls > 0
    end
    return (; passed=true, report=native_call_driver_report(program),
        storage=PSE.native_storage_report(fixture.storage))
end

"""Reject all stale old batches before running the current application once."""
function native_multibatch_stale_checks()
    reference_fixture = pb_native_fixture(; native=false, nobjects=2, steps=1,
        heterogeneous=true)
    fixture = pb_native_fixture(; native=true, nobjects=2, steps=1,
        heterogeneous=true)
    reference = PSE.run!(reference_fixture.model; steps=0, outputs=:all)
    simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
    program = compile_native_call_driver(simulation)
    batches = [batch for node in program.nodes for batch in node.batches
        if batch isa NativeRootBatch]
    @test length(batches) >= 2
    # Inject a failed capability lease without changing the valid live PSE
    # application. This deterministically exercises the defensive guard path.
    for batch in batches
        batch.lease.model_revision -= 1
    end
    PSE.continue!(reference; steps=1)
    advance_native_call_driver!(program; steps=1)
    @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
    report = native_call_driver_report(program)
    @test report.root_guard_failures == 1
    @test report.executed_numerical_roots == 0
    @test report.ordinary_batch_executions == length(batches)
    return (; passed=true, report)
end

"""Register the complete 2×2 real PB measurement without diagnostic warmup."""
function register_pb_measurement!(measurements; name::Symbol=:plantbiophysics_native,
    nobjects::Int=4, steps::Int=2, outputs=:all, replace::Bool=false,
    status_strategy::Symbol=:refs)
    status_strategy in (:refs, :direct) || throw(ArgumentError(
        "status_strategy must be :refs or :direct"))
    config = (; nobjects, steps, outputs, status_strategy)
    function construct(config, variant)
        pb_native_fixture(; native=variant.needs_native,
            nobjects=config.nobjects, steps=config.steps)
    end
    prepare(fixture, config, variant) = PSE.run!(fixture.model; steps=0, outputs=config.outputs)
    lower(simulation, fixture, config, variant) = variant.needs_driver ?
        compile_native_call_driver(simulation;
            state_strategy=variant.needs_native ? :native : :references,
            status_strategy=config.status_strategy) : nothing
    function execute!(simulation, program, fixture, config, variant)
        program === nothing ? PSE.continue!(simulation; steps=config.steps) :
            advance_native_call_driver!(program; steps=config.steps)
    end
    # Sorted exact values/types and raw streams are stable across fresh Julia
    # processes; Dict insertion/printing order is not a scientific difference.
    fingerprint(simulation, fixture, config) = CR.portable_downstream_snapshot(simulation)
    function coverage(simulation, program, fixture, config, variant)
        report = program === nothing ? nothing : native_call_driver_report(program)
        # A completed ordinary executor has invoked the same original root
        # kernels through these exact canonical cells. Count only fields with
        # real RefArray storage after positive completed runtime work.
        native_fields = fixture.native && PSE.current_step(simulation) > 0 ?
            sum(object -> count(name -> PSE.refvalue(object.status, name) isa Base.RefArray,
                keys(object.status)), PSE.model_objects(fixture.model); init=0) : 0
        driver_units = report === nothing ? 0 :
            report.executed_numerical_roots + report.executed_numerical_calls
        native_driver_units = report !== nothing && report.executed_native_column_fields > 0 ?
            driver_units : 0
        direct_driver_units = report === nothing ? 0 :
            report.executed_direct_roots + report.executed_direct_calls
        if variant.needs_native && variant.needs_driver && config.status_strategy === :direct
            direct_driver_units > 0 || throw(ArgumentError("Direct status arm performed no direct numerical work"))
        end
        return (; native_fields, driver_units, native_driver_units, direct_driver_units, report,
            storage=fixture.native ? PSE.native_storage_report(fixture.storage) : nothing)
    end
    work(simulation, fixture, config) = CR.downstream_work_report(simulation,
        [object.id for object in PSE.model_objects(fixture.model)])
    return measurements.register_case!(name; config, construct, prepare, lower,
        execute!, fingerprint, coverage, work, packages=(PSE, PB, PlantMeteo), replace)
end

include("pb_direct_status_checks.jl")
