module LeanNativeChecks

using Dates, Test, PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
const NG = Main.NativeGenericDriver
const XP = Main.NativeXPDriver
const PB = Main.NativePBDriver
const Lean = Main.LeanNativeCompiler
if !isdefined(Main, :NativeStorageFeatures)
    Base.include(Main, joinpath(@__DIR__, "storage_features.jl"))
end
const Feature = Main.NativeStorageFeatures

export lean_generic_checks, lean_mutation_checks, lean_feature_checks, lean_environment_checks,
    lean_downstream_checks, lean_all_small_checks

function lean_generic_checks()
    reports = Any[]
    @testset "Direct lean preparation: independent recurrence and canonical aliases" begin
        for value_type in (:Float32, :Float64), outputs in (:none, :all), nobjects in (1, 4)
            reference = NG.generic_native_fixture(; native=false, nobjects,
                nmodels=3, value_type)
            fixture = NG.generic_native_fixture(; native=true, nobjects,
                nmodels=3, value_type)
            control = PSE.run!(reference.model; steps=0, outputs)
            candidate = Lean.prepare_lean(fixture.model; steps=0, outputs)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            canonical = PSE.model_status(fixture.model, 1)
            escaped = PSE.refvalue(canonical, GP._stage_name(1))
            echo = PSE.model_status(fixture.model, :echo)
            @test PSE.refvalue(echo, :supply) === PSE.refvalue(canonical, GP._stage_name(3))
            @test escaped isa Base.RefArray
            for step in 1:3
                PSE.continue!(control; steps=1)
                # Deliberately use the public API; no auxiliary generated
                # executor is permitted to repair the result after each step.
                PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
                NG._check_generic_recurrence(candidate, fixture, step)
                @test PSE.model_status(fixture.model, 1) === canonical
                @test PSE.refvalue(canonical, GP._stage_name(1)) === escaped
            end
            report = Lean.lean_report(candidate)
            @test report.driver_row_executions > 0
            @test report.native_row_executions > 0
            @test report.executed_native_column_fields > 0
            # A public multi-step continuation retains the same timeline and
            # history contract after earlier step! calls.
            PSE.continue!(candidate; steps=2)
            PSE.continue!(control; steps=2)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            NG._check_generic_recurrence(candidate, fixture, 5)
            push!(reports, (; value_type, outputs, nobjects,
                report=Lean.lean_report(candidate)))
        end
    end
    return (; passed=true, cases=length(reports), reports,
        oracle=:independent_dense_recurrence_and_original_executor,
        scientific_types=(:Float32, :Float64),
        comparison=:all_values_types_ids_time_and_retained_history)
end

function lean_mutation_checks()
    reports = Any[]
    @testset "Lean mutation boundary: retire escaped references and reuse IDs" begin
        reference = NG.generic_native_fixture(; native=false, nobjects=2, nmodels=3)
        fixture = NG.generic_native_fixture(; native=true, nobjects=2, nmodels=3)
        control = PSE.run!(reference.model; steps=0, outputs=:all)
        candidate = Lean.prepare_lean(fixture.model; steps=0, outputs=:all)
        PSE.continue!(control; steps=1)
        PSE.continue!(candidate; steps=1)
        @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
        retired = PSE.refvalue(PSE.model_status(fixture.model, 2), GP._stage_name(1))
        retired_value = retired[]
        before = Lean.lean_report(candidate).driver_row_executions
        for model in (reference.model, fixture.model)
            PSE.remove_object!(model, 2)
            PSE.register_object!(model, PSE.Object(2; kind=:native_unit,
                status=NamedTuple(GP._chain_status(3, Float64, 0, 2))))
        end
        replacement = PSE.refvalue(PSE.model_status(fixture.model, 2), GP._stage_name(1))
        @test replacement !== retired
        for _ in 1:2
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
        end
        @test retired[] === retired_value
        @test replacement[] != retired_value
        @test replacement === PSE.refvalue(PSE.model_status(fixture.model, 2), GP._stage_name(1))
        report = Lean.lean_report(candidate)
        @test report.driver_row_executions >= before
        push!(reports, (case=:remove_and_readd_same_id, report))
    end
    return (; passed=true, reports,
        qualification=:external_structural_mutation_with_live_reference_retirement)
end

function lean_feature_checks()
    reports = Any[]
    @testset "Lean mixed feature preservation through original fallback" begin
        control = PSE.run!(Feature.coupling_fixture(native=false); steps=0, outputs=:all)
        candidate = Lean.prepare_lean(Feature.coupling_fixture(native=true); steps=0, outputs=:all)
        source = PSE.model_status(candidate.model, 1)
        escaped = PSE.refvalue(source, :signal)
        for step in 1:3
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test isequal(Feature._feature_snapshot(candidate), Feature._feature_snapshot(control))
            observed = PSE.final_state(candidate, :consumer)
            @test observed.single_seen === Float32(step)
            @test observed.optional_seen === -1.0f0
            @test observed.total === Float32(3step)
            @test Set(observed.seen_ids) == Set(PSE.ObjectId.((1, 2)))
            @test PSE.final_state(candidate, :temporal).observed_previous === Float32(step - 1)
        end
        @test escaped === PSE.refvalue(PSE.model_status(candidate.model, 1), :signal)
        @test PSE.final_state(candidate, 1).assigned === 10.0f0
        @test PSE.final_state(candidate, 2).assigned === 20.0f0
        push!(reports, (case=:templates_overrides_optional_many_previous_distributed,
            report=Lean.lean_report(candidate)))

        control = PSE.run!(Feature.lifecycle_fixture(native=false); steps=0, outputs=:all)
        candidate = Lean.prepare_lean(Feature.lifecycle_fixture(native=true); steps=0, outputs=:all)
        for _ in 1:2
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test isequal(Feature._feature_snapshot(candidate; ignore_native_flag=true),
                Feature._feature_snapshot(control; ignore_native_flag=true))
        end
        creator = only(PSE.model_objects(candidate.model; scale=:Root)).status
        @test creator.native_before_initializer
        @test creator.live_initializer_reference
        @test creator.manual_called
        @test creator.newborn_mass === 5.0f0
        push!(reports, (case=:mtg_newborn_initializer_manual_call,
            report=Lean.lean_report(candidate)))
    end
    return (; passed=true, reports,
        qualification=:bounded_mixed_feature_gate_not_full_suite)
end

PSE.@process "lean_environment_probe" verbose=false
struct LeanEnvironmentProbe{T} <: AbstractLean_Environment_ProbeModel
    weight::T
end
PSE.inputs_(::LeanEnvironmentProbe) = (;)
PSE.outputs_(model::LeanEnvironmentProbe) = (signal=zero(model.weight), visits=0)
PSE.environment_inputs_(model::LeanEnvironmentProbe) = (temperature=zero(model.weight),)
function PSE.run!(model::LeanEnvironmentProbe, status, environment, constants, context)
    status.signal += model.weight * environment.temperature
    status.visits += 1
    return nothing
end
CR.region_effects(::Type{<:LeanEnvironmentProbe}) = :local_ports

const EA = PSE.EnvironmentAPI
mutable struct LeanSpatialBackend <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float32}
end
EA.base_step_seconds(::LeanSpatialBackend) = 3600.0
EA.get_nsteps(::LeanSpatialBackend) = 8
EA.environment_variables(::LeanSpatialBackend) = Set((:temperature,))
EA.bind_environment(::LeanSpatialBackend, object::PSE.Object, context, config) =
    (cell=PSE.geometry(object).cell,)
EA.sample(backend::LeanSpatialBackend, handle, variable::Symbol, time) =
    variable === :temperature ? backend.values[handle.cell] : error("Unexpected variable")

function _environment_fixture(native; spatial=false)
    environment = spatial ? LeanSpatialBackend(Dict(:sun => 3.0f0, :shade => 5.0f0)) :
        (temperature=3.0f0, duration=Hour(1))
    # Empty supplied values force the actual compiler-default materialization
    # path rather than preallocating every field in the fixture.
    objects = [PSE.Object(id; kind=:probe, geometry=(cell=:sun,), status=(;)) for id in (1, 2)]
    model = PSE.CompositeModel(objects...; environment,
        applications=(PSE.ModelSpec(LeanEnvironmentProbe(2.0f0); name=:probe,
            on=PSE.Many(kind=:probe), every=Hour(2)),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
    return (; model, environment)
end

function lean_environment_checks()
    reports = Any[]
    @testset "Lean compiler defaults, global cadence and spatial invalidation" begin
        for spatial in (false, true)
            reference = _environment_fixture(false; spatial)
            fixture = _environment_fixture(true; spatial)
            control = PSE.run!(reference.model; steps=0, outputs=:all)
            candidate = Lean.prepare_lean(fixture.model; steps=0, outputs=:all)
            status = PSE.model_status(fixture.model, 1)
            @test status.signal === 0.0f0
            @test PSE.refvalue(status, :signal) isa Base.RefArray
            for _ in 1:4
                PSE.continue!(control; steps=1)
                PSE.continue!(candidate; steps=1)
                @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            end
            @test status.visits == 2
            @test status.signal === 12.0f0
            if spatial
                # Coalesce new target membership with an existing handle's
                # movement and then change the mutable environment values.
                for item in (reference, fixture)
                    PSE.register_object!(item.model, PSE.Object(3;
                        kind=:probe, geometry=(cell=:sun,), status=(;)))
                    PSE.move_object!(item.model, 1, (cell=:shade,))
                    item.environment.values[:shade] = 7.0f0
                end
                for _ in 1:2
                    PSE.continue!(control; steps=1)
                    PSE.continue!(candidate; steps=1)
                    @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
                end
                @test status.signal === 26.0f0
                @test PSE.model_status(fixture.model, 2).signal === 18.0f0
                @test PSE.model_status(fixture.model, 3).signal === 6.0f0
            else
                report = Lean.lean_report(candidate)
                @test report.driver_row_executions > 0
                @test report.executed_native_column_fields > 0
            end
            push!(reports, (; spatial, report=Lean.lean_report(candidate)))
        end
    end
    return (; passed=true, reports,
        qualification=:global_and_spatial_environment_cadence_and_compiler_defaults)
end

function lean_downstream_checks(; pb_objects=2, pb_steps=2, xp_steps=4)
    reports = Any[]
    @testset "Lean small original downstream methods and full outputs" begin
        reference = PB.pb_native_fixture(; native=false, nobjects=pb_objects, steps=pb_steps)
        fixture = PB.pb_native_fixture(; native=true, nobjects=pb_objects, steps=pb_steps)
        control = PSE.run!(reference.model; steps=0, outputs=:all)
        candidate = Lean.prepare_lean(fixture.model; steps=0, outputs=:all)
        for _ in 1:pb_steps
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
        end
        push!(reports, (case=:plantbiophysics_original_hard_call_fallback,
            report=Lean.lean_report(candidate)))

        weather = CR._xpalm_fixture_weather(xp_steps)
        control = PSE.run!(XP.xpalm_native_fixture(; steps=xp_steps, weather, native=false);
            steps=0, outputs=:all)
        candidate = Lean.prepare_lean(XP.xpalm_native_fixture(; steps=xp_steps, weather, native=true);
            steps=0, outputs=:all)
        initial_ids = collect(PSE.object_ids(candidate.model))
        @test XP.xp_semantic_digest(candidate) == XP.xp_semantic_digest(control)
        for _ in 1:xp_steps
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test XP.xp_semantic_digest(candidate) == XP.xp_semantic_digest(control)
        end
        work = CR.downstream_work_report(candidate, initial_ids)
        @test length(work.added_ids) >= 3
        report = Lean.lean_report(candidate)
        @test report.driver_row_executions > 0
        @test report.executed_native_column_fields > 0
        push!(reports, (case=:xpalm_original_growth_and_initializer,
            work, report))
    end
    return (; passed=true, reports,
        qualification=:small_downstream_computational_parity_not_biological_validation)
end

function lean_all_small_checks()
    return (generic=lean_generic_checks(), mutation=lean_mutation_checks(),
        features=lean_feature_checks(), environment=lean_environment_checks(),
        downstream=lean_downstream_checks())
end

end # module
