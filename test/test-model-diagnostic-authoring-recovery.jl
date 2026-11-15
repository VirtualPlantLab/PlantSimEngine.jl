module DiagnosticAuthoringRecoveryChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "diagnostic_authoring_recovery_good" verbose=false
PSE.@process "diagnostic_authoring_recovery_broken" verbose=false
PSE.@process "diagnostic_authoring_recovery_coupled" verbose=false
struct Good{N} <: AbstractDiagnostic_Authoring_Recovery_GoodModel end
PSE.inputs_(::Good) = NamedTuple()
PSE.outputs_(::Good{N}) where {N} = NamedTuple{(N,)}((0.0,))
function PSE.run!(::Good{N}, status, environment, constants, context) where {N}
    setproperty!(status, N, getproperty(status, N) + 1.0)
    return nothing
end

struct OpaqueDeclarationError <: Exception
    owner::Module
end
Base.showerror(io::IO, ::OpaqueDeclarationError) = print(io, "opaque declaration failed once")
const broken_calls = Ref(0)
struct Broken <: AbstractDiagnostic_Authoring_Recovery_BrokenModel end
PSE.inputs_(::Broken) = NamedTuple()
function PSE.outputs_(::Broken)
    broken_calls[] += 1
    throw(OpaqueDeclarationError(@__MODULE__))
end

struct Coupled <: AbstractDiagnostic_Authoring_Recovery_CoupledModel end
PSE.inputs_(::Coupled) = (driver=Required(Float64),)
PSE.outputs_(::Coupled) = (after=0.0,)
PSE.run!(::Coupled, status, environment, constants, context) =
    (status.after = status.driver + 1.0; nothing)

struct BadProcess <: AbstractModel end
PSE.process(::BadProcess) = 42

@testset "diagnostic recovery uses captured authoring and keeps valid later applications" begin
    broken_calls[] = 0
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(Good{:before}(); name=:before, on=One(id=:root)),
        ModelSpec(Broken(); name=:broken, on=One(id=:root)),
        ModelSpec(Good{:after}(); name=:after, on=One(id=:root)),
    ), environment=(duration=Hour(1),))
    preparation = model.scenario_plan_cache
    @test broken_calls[] == 1
    @test length(preparation.authored) == 3
    @test preparation.authored[1] isa PSE.AuthoredApplicationRecipe
    @test preparation.authored[2] isa PSE.ScenarioPreparationFailure
    @test preparation.authored[3] isa PSE.AuthoredApplicationRecipe
    @test preparation.failure === preparation.authored[2]
    @test preparation.failure.phase === :output_ports
    @test preparation.failure.application_id === :broken
    @test preparation.status_manifest isa PSE.PreparedStatusManifest
    @test model.registry.objects.catalog isa PSE.ClosedObjectFamilyCatalog
    @test PSE._prepared_status_manifest(model) === preparation.status_manifest

    for _ in 1:2
        report = PSE.compile_model_report(model)
        @test [application.id for application in report.applications] == [:before, :after]
        @test any(row -> row.application_ids == [:broken] &&
            row.code === :output_ports_error && occursin("opaque declaration", row.message),
            report.diagnostics)
        @test broken_calls[] == 1 # module-global state cannot be hidden by deepcopy
        @test report.model !== model
        @test report.model.scenario_plan_cache.failure.error === preparation.failure.error
        @test report.model.registry.objects.catalog isa PSE.ClosedObjectFamilyCatalog
        @test PSE._prepared_status_manifest(report.model) ===
            report.model.scenario_plan_cache.status_manifest
    end
    @test isnothing(model_status(model, :root))
    @test model.scenario_plan_cache === preparation
    @test isnothing(preparation.resolved)
    @test isnothing(PSE.Advanced.compiled_bindings(model))

    # Runtime and topology/cadence refreshes keep the original error frozen.
    register_object!(model, Object(:other; scale=:Scene))
    @test model_status(model, :other) === nothing
    @test PSE._prepared_status_manifest(model) === preparation.status_manifest
    @test broken_calls[] == 1
    model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(model)
    @test_throws OpaqueDeclarationError run!(model; steps=0)
    @test_throws OpaqueDeclarationError PSE._prepare_scenario_plan(model; force=true)
    @test broken_calls[] == 1
    @test model.scenario_plan_cache === preparation
    @test_throws OpaqueDeclarationError PSE.compile_model_report(model; strict=true)
    @test broken_calls[] == 1
end

@testset "recovered later applications retain authored slots and coupled inputs" begin
    broken_calls[] = 0
    model = CompositeModel(Object(:root; scale=:Scene,
        status=Status(before=2.0, driver=0.0, after=0.0)); applications=(
        ModelSpec(Good{:before}(); name=:before, on=One(id=:root)),
        ModelSpec(Broken(); name=:broken, on=One(id=:root)),
        ModelSpec(Coupled(); name=:after, on=One(id=:root),
            inputs=(driver=One(within=Self(), application=:before, var=:before),)),
    ))
    preparation = model.scenario_plan_cache
    original = model_status(model, :root)
    original_driver = PSE.refvalue(original, :driver)
    @test model.registry.objects.catalog isa PSE.ClosedObjectFamilyCatalog
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:before, :after]
    @test [application.slot for application in report.applications] == [1, 3]
    @test typeof(model_status(report.model, :root)) === preparation.status_manifest.status_type
    @test length(report.input_bindings) == 1
    binding = only(report.input_bindings)
    @test binding.application_id === :after
    @test binding.input === :driver
    @test binding.source_ids == [ObjectId(:root)]
    @test binding.source_application_ids == [:before]
    @test binding.plan.application_slot == 3
    @test binding.plan.slot == only(preparation.program.input_records).slot
    @test PSE.refvalue(model_status(report.model, :root), :driver) ===
          PSE.refvalue(model_status(report.model, :root), :before)
    @test model_status(model, :root).driver == 0.0
    @test model_status(model, :root) === original
    @test PSE.refvalue(original, :driver) === original_driver
    @test PSE.refvalue(model_status(report.model, :root), :driver) !== original_driver
    @test !any(row -> row.phase === :input_status, report.diagnostics)
    @test !any(row -> occursin("BoundsError", row.message), report.diagnostics)
    @test broken_calls[] == 1
end

@testset "normalization failures do not hide later valid declarations" begin
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        42,
        ModelSpec(Good{:after}(); name=:after, on=One(id=:root)),
    ))
    preparation = model.scenario_plan_cache
    @test preparation.authored[1] isa PSE.ScenarioPreparationFailure
    @test preparation.authored[2] isa PSE.AuthoredApplicationRecipe
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:after]
    @test !isempty(report.diagnostics)

    bad_process = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(BadProcess(); name=:bad_process, on=One(id=:root)),
        ModelSpec(Good{:after}(); name=:after, on=One(id=:root)),
    ))
    @test bad_process.scenario_plan_cache.failure.phase === :application_identifiers
    @test bad_process.scenario_plan_cache.failure.error isa ArgumentError
    process_report = PSE.compile_model_report(bad_process)
    @test [application.id for application in process_report.applications] == [:after]
    @test any(row -> occursin("process identifier must be a Symbol", row.message),
        process_report.diagnostics)
end

@testset "membership failures recover valid applications through the same resolver" begin
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(Good{:before}(); name=:before, on=One(id=:root)),
        ModelSpec(Good{:missing}(); name=:missing, on=One(id=:missing)),
        ModelSpec(Good{:after}(); name=:after, on=One(id=:root)),
    ))
    @test isnothing(model.scenario_plan_cache.failure)
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:before, :after]
    @test any(row -> row.phase === :application_recovery && row.application_ids == [:missing],
        report.diagnostics)
    register_object!(model, Object(:missing; scale=:Leaf))
    repaired = PSE.compile_model_report(model)
    @test [application.id for application in repaired.applications] == [:before, :missing, :after]
    @test isempty(repaired.diagnostics)
end


@testset "invalid environment source names keep editable application metadata" begin
    model = CompositeModel(Object(:root; scale=:Scene, status=Status(seed=1.0));
        applications=(
            ModelSpec(Good{:signal}(); name=:configured, on=One(id=:root),
                environment=Environment(sources=(T=:temperature,))),
            ModelSpec(Good{:later}(); name=:later, on=One(id=:root)),
        ))
    original = model_status(model, :root)
    for _ in 1:2
        report = PSE.compile_model_report(model)
        @test [application.id for application in report.applications] == [:configured, :later]
        configured = only(application for application in report.applications
            if application.id === :configured)
        @test environment_config(configured.spec).config.sources == (T=:temperature,)
        @test configured.target_ids == [ObjectId(:root)]
        @test configured.clock.dt == 1.0
        @test any(diagnostic -> diagnostic.application_ids == [:configured] &&
            occursin("unknown model-facing environment input", diagnostic.message),
            report.diagnostics)
        @test isnothing(report.compiled)
        @test model_status(model, :root) === original
        @test !hasproperty(original, :signal)
    end
    @test_throws ErrorException PSE.compile_model_report(model; strict=true)
    @test_throws ErrorException run!(model; steps=0)
end

const failed_environment_port_reads = Ref(0)
struct FailedEnvironmentPorts <: AbstractDiagnostic_Authoring_Recovery_GoodModel end
PSE.inputs_(::FailedEnvironmentPorts) = NamedTuple()
PSE.outputs_(::FailedEnvironmentPorts) = (signal=0.0,)
function PSE.environment_inputs_(::FailedEnvironmentPorts)
    failed_environment_port_reads[] += 1
    throw(OpaqueDeclarationError(@__MODULE__))
end

@testset "recovery never retries an environment declaration that itself failed" begin
    failed_environment_port_reads[] = 0
    model = CompositeModel(Object(:root; scale=:Scene); applications=(
        ModelSpec(FailedEnvironmentPorts(); name=:failed, on=One(id=:root),
            environment=Environment(sources=(T=:temperature,))),
        ModelSpec(Good{:later}(); name=:later, on=One(id=:root)),
    ))
    @test failed_environment_port_reads[] == 1
    for _ in 1:2
        report = PSE.compile_model_report(model)
        @test [application.id for application in report.applications] == [:later]
        @test failed_environment_port_reads[] == 1
        @test any(diagnostic -> diagnostic.application_ids == [:failed] &&
            occursin("opaque declaration failed once", diagnostic.message),
            report.diagnostics)
    end
end

const masked_contract_reads = Ref(0)
struct MaskedContractReader <: AbstractDiagnostic_Authoring_Recovery_CoupledModel end
PSE.inputs_(::MaskedContractReader) = (driver=Required(Real),)
PSE.outputs_(::MaskedContractReader) = (after=0.0,)
PSE.run!(::MaskedContractReader, status, environment, constants, context) = nothing
PSE.variable_contracts_(::Good{:contract_signal}) =
    (contract_signal=VariableContract(unit=:source_unit),)
function PSE.variable_contracts_(::MaskedContractReader)
    masked_contract_reads[] += 1
    return (driver=VariableContract(unit=:sink_unit),)
end

@testset "a captured route contract error precedes its missing manifest family" begin
    masked_contract_reads[] = 0
    model = CompositeModel(Object(:source), Object(:reader); applications=(
        ModelSpec(Good{:contract_signal}(); name=:source, on=One(id=:source)),
        ModelSpec(MaskedContractReader(); name=:reader, on=One(id=:reader),
            inputs=(driver=One(SceneScope(); id=:source,
                application=:source, var=:contract_signal),)),
    ), environment=(duration=Hour(1),))
    preparation = model.scenario_plan_cache
    route_failure = only(preparation.program.input_records)
    @test route_failure isa PSE.ScenarioPreparationFailure
    @test route_failure.phase === :input_plans
    @test occursin("Incompatible variable contracts", sprint(showerror, route_failure.error))
    @test preparation.status_manifest isa PSE.ScenarioPreparationFailure
    @test preparation.status_manifest.error !== route_failure.error
    @test preparation.failure === route_failure
    reads = masked_contract_reads[]
    @test reads > 0
    for operation in (
        () -> run!(model; steps=0, outputs=:none),
        () -> Advanced.refresh_bindings!(model),
    )
        caught = try
            operation()
        catch error
            error
        end
        @test caught === route_failure.error
        @test model.scenario_plan_cache === preparation
        @test masked_contract_reads[] == reads
        @test model_status(model, :source) === nothing
        @test model_status(model, :reader) === nothing
    end
    # The aggregate first failure does not erase the valid authored records.
    report = PSE.compile_model_report(model)
    @test [application.id for application in report.applications] == [:source, :reader]
    @test any(row -> row.phase === :input_plans &&
        occursin("Incompatible variable contracts", row.message), report.diagnostics)
    @test masked_contract_reads[] == reads
end

end
