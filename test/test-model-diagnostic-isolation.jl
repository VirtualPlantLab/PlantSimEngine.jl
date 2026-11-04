using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "diagnostic_isolation_source" verbose=false
PlantSimEngine.@process "diagnostic_isolation_reader" verbose=false

struct DiagnosticIsolationSource <: AbstractDiagnostic_Isolation_SourceModel end
struct DiagnosticIsolationReader <: AbstractDiagnostic_Isolation_ReaderModel end
struct DiagnosticIsolationLagReader <: AbstractDiagnostic_Isolation_ReaderModel end

PlantSimEngine.outputs_(::DiagnosticIsolationSource) = (signal=0.0,)
PlantSimEngine.inputs_(::DiagnosticIsolationReader) = (signal=Required(Float64),)
PlantSimEngine.inputs_(::DiagnosticIsolationLagReader) = (lagged=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::Union{DiagnosticIsolationReader,DiagnosticIsolationLagReader}) = (observed=0.0,)

function PlantSimEngine.run!(::DiagnosticIsolationSource, status, environment, constants, context)
    status.signal += 1.0
    return nothing
end

function PlantSimEngine.run!(::DiagnosticIsolationReader, status, environment, constants, context)
    status.observed = status.signal
    return nothing
end

function PlantSimEngine.run!(::DiagnosticIsolationLagReader, status, environment, constants, context)
    status.observed = sum(status.lagged)
    return nothing
end

@testset "Model diagnostics preserve an authored scenario" begin
    model = CompositeModel(DiagnosticIsolationReader(), DiagnosticIsolationSource(); status=(signal=4.0,))
    status = model_status(model, :scene)
    @test getproperty.(explain_schedule(model), :application_id) ==
          [:diagnostic_isolation_source, :diagnostic_isolation_reader]
    @test only(explain_bindings(model)).source_application_ids == [:diagnostic_isolation_source]

    for explain in (explain_applications, explain_calls, explain_output_bindings, explain_writers,
        explain_initialization, explain_execution_plan, explain_output_retention, explain_environment_bindings)
        @test explain(model) isa AbstractVector
    end

    @test model_status(model, :scene) === status
    @test NamedTuple(status) == (signal=4.0,)
    @test isnothing(Advanced.compiled_bindings(model))
    program = Compilation.prepare(model)
    step!(program)
    @test final_state(program).observed == 5.0
end

function diagnostic_isolation_growth_model()
    return CompositeModel(
        Object(:plant; scale=:Plant, status=Status(lagged=[0.0])),
        Object(:leaf_a; scale=:Leaf, parent=:plant, status=Status(signal=1.0));
        applications=(
            ModelSpec(DiagnosticIsolationSource(); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(DiagnosticIsolationLagReader(); name=:reader, on=One(scale=:Plant),
                inputs=(PreviousTimeStep(:lagged) => Many(
                    scale=:Leaf, within=Subtree(), application=:source, var=:signal,
                ),)),
        ),
    )
end

function register_diagnostic_isolation_leaf!(model)
    return register_object!(model, Object(:leaf_b; scale=:Leaf, parent=:plant, status=Status(signal=10.0)))
end

@testset "Model diagnostics preserve pending runtime changes" begin
    model = diagnostic_isolation_growth_model()
    simulation = run!(model; steps=2, outputs=:all)
    binding = only(simulation.compiled.input_bindings)
    carrier = input_carrier(binding)
    # Structured rows own their metadata. The carrier accessor still exposes
    # the live reference storage from an explicit compiled input binding.
    empty!(only(explain_bindings(model)).source_application_ids)
    @test binding.source_application_ids == [:source]
    stream_key = (:source, ObjectId(:leaf_a), :signal)
    retained = outputs(simulation)[stream_key]
    samples = copy(retained)

    register_diagnostic_isolation_leaf!(model)
    source_row = only(row for row in explain_schedule(model) if row.application_id == :source)
    @test source_row.target_ids == [:leaf_a, :leaf_b]
    @test only(explain_bindings(model)).source_ids == [:leaf_a, :leaf_b]
    @test Advanced.bindings_dirty(model)
    @test Advanced.environment_bindings_dirty(model)
    @test simulation.compiled.applications_by_id.source.target_ids == [ObjectId(:leaf_a)]
    @test binding.source_ids == [ObjectId(:leaf_a)]
    @test input_carrier(binding) === carrier
    @test outputs(simulation)[stream_key] === retained
    @test retained == samples

    continue!(simulation; steps=2)
    control_model = diagnostic_isolation_growth_model()
    control = run!(control_model; steps=2, outputs=:all)
    register_diagnostic_isolation_leaf!(control_model)
    continue!(control; steps=2)
    @test final_state(simulation, :plant) == final_state(control, :plant)
    @test outputs(simulation) == outputs(control)
    @test outputs(simulation)[stream_key] === retained
end
