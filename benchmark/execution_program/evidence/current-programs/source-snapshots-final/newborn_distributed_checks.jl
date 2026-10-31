module NewbornDistributedChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const NP = Main.NewbornPreparation
const Checks = Main.NewbornPreparationChecks

export newborn_distributed_checks

# A new test type; no existing model/cache struct layout changes are needed.
struct PreparationDistributedWriter <: Checks.AbstractPreparation_SourceModel end
PSE.inputs_(::PreparationDistributedWriter) = (;)
PSE.outputs_(::PreparationDistributedWriter) = (
    distributed_signal=PSE.Distributed(PSE.Default(0.0f0)), writer_runs=0)
function PSE.run!(::PreparationDistributedWriter, status, environment, constants, context)
    status.writer_runs += 1
    targets = PSE.output_targets(context, (:distributed_signal,))
    targets.columns.distributed_signal .= Float32(5 + status.writer_runs)
    return nothing
end

function distributed_fixture(mode)
    base = Checks.preparation_fixture()
    applications = Any[PSE.ModelSpec(PreparationDistributedWriter();
        name=:distributed_writer, on=PSE.One(id=0), every=Hour(1),
        outputs_to=(PSE.OutputTo(PSE.Many(kind=:preparation_unit,
            within=PSE.Subtree()); vars=(:distributed_signal,)),)),
        base.model.applications...]
    if mode !== :unrelated
        # An existing destination already owns its distributed canonical cell
        # during newborn targeted preparation. Empty source-app metadata in the
        # from_status case must not bypass the actual field-ownership guard.
        selector = mode === :from_status ? PSE.Many(id=1, within=PSE.SceneScope(),
            var=:distributed_signal, from_status=true) :
            PSE.Many(id=1, within=PSE.SceneScope(), application=:distributed_writer,
                var=:distributed_signal)
        index = findfirst(spec -> spec.name === :probe, applications)
        applications[index] = PSE.ModelSpec(Checks.PreparationProbe(); name=:probe,
            on=PSE.Many(kind=:preparation_unit), every=Hour(1), inputs=(signals=selector,))
    end
    return PSE.CompositeModel(PSE.Object(0), PSE.Object(1;
        kind=:preparation_unit, parent=0, geometry=(cell=:initial,),
        status=(supply=7.0f0, mass=1.0f0, previous=1.0f0, initializer_runs=0));
        applications, environment=base.weather)
end

function newborn_distributed_checks()
    reports = Any[]
    @testset "Per-binding newborn promotion alongside distributed outputs" begin
        for mode in (:unrelated, :direct, :from_status)
            reference = PSE.run!(distributed_fixture(mode); steps=0, outputs=:all)
            candidate = NP.prepare_newborn(distributed_fixture(mode); steps=0, outputs=:all)
            escaped = PSE.refvalue(PSE.model_status(candidate.model, 1), :distributed_signal)
            for step in 1:3
                PSE.step!(reference)
                PSE.step!(candidate)
                @test isequal(Checks._snapshot(candidate), Checks._snapshot(reference))
                @test PSE.refvalue(PSE.model_status(candidate.model, 1),
                    :distributed_signal) === escaped
                @test escaped[] === Float32(5 + step)
            end
            report = NP.newborn_preparation_report(candidate)
            @test report.captured_bindings > 0
            @test report.promoted_bindings > 0 # local initializer remains eligible
            if mode === :unrelated
                @test !haskey(report.capture_rejections, :capture_distributed_source_owner)
                @test !haskey(report.capture_rejections, :capture_distributed_source_declaration)
            else
                reason = mode === :from_status ? :distributed_source_owner :
                    :distributed_source_declaration
                @test get(report.capture_rejections, Symbol("capture_", reason), 0) > 0
                binding = only(candidate.compiled.input_bindings_by_target[
                    (:probe, PSE.ObjectId(10))])
                stamp, actual_reason = NP._binding_stamp(candidate.model,
                    candidate.compiled, binding)
                @test isnothing(stamp)
                @test actual_reason === reason
                @test only(parent(binding.carrier)) === escaped
                if mode === :from_status
                    @test isempty(binding.source_application_ids)
                end
            end
            push!(reports, (; mode, report))
        end
    end
    return (; passed=true, reports,
        oracle=:ordinary_per_step_full_state_history_and_distributed_canonical_refs)
end

end # module
