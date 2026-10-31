# Small integration gates for features deliberately kept behind ordered boundaries.
# Included inside GeneratedProgramExperiment after the existing fixture helpers.

PSE.@process "program_completion_optional_controller" verbose=false
struct CompletionOptionalController <: AbstractProgram_Completion_Optional_ControllerModel end
PSE.inputs_(::CompletionOptionalController) = NamedTuple()
PSE.outputs_(::CompletionOptionalController) =
    (present_count=0, absent_count=-1, observed=-1.0, visits=0)
function PSE.run!(::CompletionOptionalController, status, environment, constants, context)
    present = PSE.run_call!(context, :present; publish=true)
    absent = PSE.run_call!(context, :absent; publish=true)
    status.present_count = length(present)
    status.absent_count = length(absent)
    status.observed = only(present).status.value
    status.visits += 1
    return nothing
end
function completion_optional_fixture()
    return PSE.CompositeModel(PSE.Object(:owner), PSE.Object(:worker; parent=:owner);
        applications=(
            PSE.ModelSpec(CompletionOptionalController(); name=:controller,
                on=PSE.One(id=:owner), every=Hour(1), calls=(
                    present=PSE.OptionalOne(id=:worker, within=PSE.SceneScope(),
                        application=:worker),
                    absent=PSE.OptionalOne(id=:absent, within=PSE.SceneScope(),
                        application=:worker),)),
            PSE.ModelSpec(ProgramCallWorker(); name=:worker,
                on=PSE.One(id=:worker), every=Hour(1)),
        ), environment=(duration=Hour(1),))
end

PSE.@process "program_completion_initializer" verbose=false
PSE.@process "program_completion_creator" verbose=false
PSE.@process "program_completion_newborn_observer" verbose=false
struct CompletionInitializer <: AbstractProgram_Completion_InitializerModel end
struct CompletionCreator <: AbstractProgram_Completion_CreatorModel end
struct CompletionNewbornObserver <: AbstractProgram_Completion_Newborn_ObserverModel end
PSE.inputs_(::CompletionInitializer) = (previous_mass=PSE.Required(Float64),)
PSE.outputs_(::CompletionInitializer) = (mass=0.0, initializer_runs=0)
function PSE.run!(::CompletionInitializer, status, environment, constants, context)
    status.mass = status.previous_mass + 1.0
    status.initializer_runs += 1
    return nothing
end
PSE.inputs_(::CompletionCreator) = NamedTuple()
PSE.outputs_(::CompletionCreator) =
    (created=false, initialized_mass=-1.0, duplicate_rejected=false)
function PSE.run!(::CompletionCreator, status, environment, constants, context)
    status.created && return nothing
    object = PSE.register_object!(PSE.runtime_model(context),
        PSE.Object(:new_unit; kind=:newborn_unit, parent=:owner,
            status=PSE.Status(mass=4.0, previous_mass=4.0, initializer_runs=0)))
    initialized = PSE.run_initializer!(context, :newborn, object)
    status.initialized_mass = initialized.mass
    try
        PSE.run_initializer!(context, :newborn, object)
    catch error_
        status.duplicate_rejected = occursin("already initialized", sprint(showerror, error_))
    end
    status.created = true
    return nothing
end
PSE.inputs_(::CompletionNewbornObserver) = (mass=PSE.Required(Float64),)
PSE.outputs_(::CompletionNewbornObserver) = (observed_mass=-1.0, observer_runs=0)
function PSE.run!(::CompletionNewbornObserver, status, environment, constants, context)
    status.observed_mass = status.mass
    status.observer_runs += 1
    return nothing
end
function completion_initializer_fixture()
    return PSE.CompositeModel(PSE.Object(:owner); applications=(
        PSE.ModelSpec(CompletionNewbornObserver(); name=:observer,
            on=PSE.Many(kind=:newborn_unit), every=Hour(1), inputs=(
                mass=PSE.One(within=PSE.Self(), application=:initializer, var=:mass),)),
        PSE.ModelSpec(CompletionCreator(); name=:creator,
            on=PSE.One(id=:owner), every=Hour(1), calls=(
                newborn=PSE.Initializer(PSE.One(kind=:newborn_unit,
                    within=PSE.SceneScope(), application=:initializer)),)),
        PSE.ModelSpec(CompletionInitializer(); name=:initializer,
            on=PSE.Many(kind=:newborn_unit), every=Hour(1), inputs=(
                previous_mass=PSE.One(within=PSE.Self(), application=:initializer,
                    var=:mass, policy=PSE.PreviousTimeStep(:previous_mass)),)),
    ), environment=(duration=Hour(1),))
end

const CompletionEA = PSE.EnvironmentAPI
mutable struct CompletionSpatialBackend <: CompletionEA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    samples::Vector{Tuple{Symbol,Symbol,Symbol,Int,Float64}}
end
CompletionSpatialBackend() = CompletionSpatialBackend(
    Dict(:sun=>10.0, :shade=>20.0), Tuple{Symbol,Symbol,Symbol,Int,Float64}[])
CompletionEA.base_step_seconds(::CompletionSpatialBackend) = 3600.0
CompletionEA.get_nsteps(::CompletionSpatialBackend) = 8
CompletionEA.environment_variables(::CompletionSpatialBackend) = Set((:T,))
function CompletionEA.bind_environment(::CompletionSpatialBackend,
    object::PSE.Object, context, config)
    location = PSE.geometry(object)
    cell = isnothing(location) ? :sun : location.cell
    return (; cell, application=context.application, object_id=context.object_id)
end
function CompletionEA.sample(backend::CompletionSpatialBackend, handle,
    variable::Symbol, time)
    variable === :T || error("Unexpected completion backend variable $(variable)")
    value = backend.values[handle.cell]
    push!(backend.samples,
        (handle.application, handle.object_id.value, handle.cell, Int(time), value))
    return value
end
PSE.@process "program_completion_spatial_probe" verbose=false
struct CompletionSpatialProbe <: AbstractProgram_Completion_Spatial_ProbeModel end
PSE.inputs_(::CompletionSpatialProbe) = NamedTuple()
PSE.outputs_(::CompletionSpatialProbe) = (seen=0.0, visits=0)
PSE.environment_inputs_(::CompletionSpatialProbe) = (T=0.0,)
function PSE.run!(::CompletionSpatialProbe, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    return nothing
end
# The kernel itself is local; its spatial provider still prohibits trajectory
# lowering, so this exercises provider eligibility rather than only unknown effects.
program_effects(::Type{CompletionSpatialProbe}) = :local
function completion_spatial_fixture()
    backend = CompletionSpatialBackend()
    model = PSE.CompositeModel(
        PSE.Object(:scene; status=PSE.Status()),
        PSE.Object(:a; parent=:scene, geometry=(cell=:sun,), status=PSE.Status()),
        PSE.Object(:b; parent=:scene, geometry=(cell=:sun,), status=PSE.Status()),
        PSE.Object(:unit; parent=:a, kind=:spatial_unit, status=PSE.Status());
        applications=(
            PSE.ModelSpec(CompletionSpatialProbe(); name=:a_probe,
                on=PSE.Many(kind=:spatial_unit, within=PSE.Scope(PSE.ObjectId(:a))),
                every=Hour(1), environment=PSE.Environment(provider=:completion_spatial)),
            PSE.ModelSpec(CompletionSpatialProbe(); name=:b_probe,
                on=PSE.Many(kind=:spatial_unit, within=PSE.Scope(PSE.ObjectId(:b))),
                every=Hour(1), environment=PSE.Environment(provider=:completion_spatial)),
        ), environment=backend)
    return (; model, backend)
end

PSE.@process "program_completion_validated_assignment" verbose=false
struct CompletionValidatedAssignment <: AbstractProgram_Completion_Validated_AssignmentModel end
PSE.inputs_(::CompletionValidatedAssignment) = NamedTuple()
PSE.outputs_(::CompletionValidatedAssignment) =
    (energy=PSE.Distributed(PSE.Default(0.0)), rejected=false,
        unchanged_after_rejection=false, visits=0)
function PSE.run!(::CompletionValidatedAssignment, status, environment, constants, context)
    destinations = PSE.output_targets(context, (:energy,))
    ids = collect(PSE.object_ids(destinations))
    before = collect(destinations.columns.energy)
    status.visits += 1
    invalid_ids = [first(ids), first(ids)]
    status.rejected = false
    try
        PSE.assign_outputs!(destinations, invalid_ids, (energy=[91.0, 92.0],))
    catch error_
        status.rejected = error_ isa ArgumentError
    end
    status.unchanged_after_rejection = collect(destinations.columns.energy) == before
    values = [Float64(10 * row + status.visits) for row in eachindex(ids)]
    PSE.assign_outputs!(destinations, ids, (energy=values,))
    return nothing
end
function completion_assignment_fixture()
    return PSE.CompositeModel(PSE.Object(:owner),
        PSE.Object(:unit_a; kind=:destination, status=PSE.Status()),
        PSE.Object(:unit_b; kind=:destination, status=PSE.Status()); applications=(
            PSE.ModelSpec(CompletionValidatedAssignment(); name=:writer,
                on=PSE.One(id=:owner), every=Hour(1), outputs_to=(
                    PSE.OutputTo(PSE.Many(kind=:destination, within=PSE.SceneScope());
                        vars=(:energy,)),)),
        ), environment=(duration=Hour(1),))
end

function _completion_compile(simulation, backend::Symbol)
    backend === :typed && return compile_program(simulation; strategy=:typed)
    backend === :trajectory && return compile_temporal_program(simulation; prepared=true)
    throw(ArgumentError("Unknown completion backend $(backend)"))
end
function _completion_fallback_report(program, backend)
    report = strategy_report(program)
    if backend === :trajectory
        @test !report.temporal_selected
    else
        @test report.ordered_applications > 0 ||
            (hasproperty(report, :environment_barrier_applications) &&
                report.environment_barrier_applications > 0)
    end
    return report
end
function _completion_equal(simulation, reference)
    @test isequal(fingerprint(simulation).states, fingerprint(reference).states)
    @test isequal(fingerprint(simulation).histories, fingerprint(reference).histories)
    @test PSE.current_step(simulation) == PSE.current_step(reference)
    return nothing
end

"""Four tiny feature cases, through both actual typed and trajectory-request paths."""
function run_feature_completion_checks(; backends=(:typed, :trajectory))
    reports = NamedTuple[]
    @testset "generated program remaining feature boundaries" begin
        for backend in backends
            for (name, builder) in ((:optional_targets, completion_optional_fixture),
                (:newborn_initializer, completion_initializer_fixture),
                (:validated_distributed_assignment, completion_assignment_fixture))
                reference = PSE.run!(builder(); steps=2, outputs=:all)
                simulation = PSE.run!(builder(); steps=0, outputs=:all)
                program = _completion_compile(simulation, backend)
                advance_program!(program; steps=2)
                _completion_equal(simulation, reference)
                report = _completion_fallback_report(program, backend)
                if name === :optional_targets
                    state = PSE.final_state(simulation, :owner)
                    @test state.present_count == 1
                    @test state.absent_count == 0
                    @test state.observed == 1.0
                    @test PSE.final_state(simulation, :worker).visits == 2
                elseif name === :newborn_initializer
                    owner = PSE.final_state(simulation, :owner)
                    newborn = PSE.final_state(simulation, :new_unit)
                    @test owner.created && owner.duplicate_rejected
                    @test owner.initialized_mass == 5.0
                    @test newborn.mass == newborn.observed_mass == 6.0
                    @test newborn.initializer_runs == newborn.observer_runs == 2
                    initializer_samples = PSE.outputs(simulation)[
                        (:initializer, PSE.ObjectId(:new_unit), :mass)]
                    observer_samples = PSE.outputs(simulation)[
                        (:observer, PSE.ObjectId(:new_unit), :observed_mass)]
                    @test collect(initializer_samples) == [(2.0, 6.0)]
                    @test last.(collect(observer_samples)) == [5.0, 6.0]
                else
                    owner = PSE.final_state(simulation, :owner)
                    @test owner.rejected
                    @test owner.unchanged_after_rejection
                    @test PSE.final_state(simulation, :unit_a).energy == 12.0
                    @test PSE.final_state(simulation, :unit_b).energy == 22.0
                end
                push!(reports, (; case=name, backend, report))
            end

            reference_scene = completion_spatial_fixture()
            scene = completion_spatial_fixture()
            reference = PSE.run!(reference_scene.model; steps=0, outputs=:all)
            simulation = PSE.run!(scene.model; steps=0, outputs=:all)
            program = _completion_compile(simulation, backend)
            empty!(reference_scene.backend.samples)
            empty!(scene.backend.samples)
            for step in 1:4
                if step == 2
                    PSE.move_object!(reference_scene.model, :a, (cell=:shade,))
                    PSE.move_object!(scene.model, :a, (cell=:shade,))
                elseif step == 3
                    PSE.reparent_object!(reference_scene.model, :unit, :b)
                    PSE.reparent_object!(scene.model, :unit, :b)
                elseif step == 4
                    reference_scene.backend.values[:sun] = 31.0
                    scene.backend.values[:sun] = 31.0
                end
                PSE.continue!(reference; steps=1)
                advance_program!(program; steps=1)
                _completion_equal(simulation, reference)
                @test scene.backend.samples == reference_scene.backend.samples
                expected = (10.0, 20.0, 10.0, 31.0)[step]
                @test PSE.final_state(simulation, :unit).seen == expected
                @test PSE.final_state(simulation, :unit).visits == step
            end
            @test length(PSE.outputs(simulation)[(:a_probe, PSE.ObjectId(:unit), :seen)]) == 2
            @test length(PSE.outputs(simulation)[(:b_probe, PSE.ObjectId(:unit), :seen)]) == 2
            report = _completion_fallback_report(program, backend)
            push!(reports, (; case=:spatial_movement_and_reparenting, backend, report))
        end
    end
    return (; cases=length(reports), reports)
end
