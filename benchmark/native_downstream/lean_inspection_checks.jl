module LeanNativeInspectionChecks

using Dates, Test, PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const Lean = Main.LeanNativeCompiler

if !isdefined(Main, :LeanReadableSource)
    Base.include(Main, joinpath(@__DIR__, "lean_inspection_models.jl"))
end
const LeanReadableSource = Main.LeanReadableSource
const LeanReadableConsumer = Main.LeanReadableConsumer

function _fixture(native)
    storage = native ? PSE.NativeColumnStorage() : nothing
    objects = (PSE.Object(1; kind=:source, status=(value=0.0f0, visits=0)),
        PSE.Object(2; kind=:source, status=(value=0.0f0, visits=0)),
        PSE.Object(3; kind=:consumer, status=(observed=0.0f0, visits=0)))
    return PSE.CompositeModel(objects...; status_storage=storage,
        environment=(temperature=3.0f0, duration=Hour(1)),
        applications=(
            PSE.ModelSpec(LeanReadableSource(2.0f0); name=:source,
                on=PSE.Many(kind=:source), every=Hour(1)),
            PSE.ModelSpec(LeanReadableConsumer{Float32}(); name=:consumer,
                on=PSE.One(id=3), every=Hour(1), inputs=(
                    supply=PSE.One(id=1, within=PSE.SceneScope(),
                        application=:source, var=:value),)),))
end

"""
Qualify actual readable-source execution on a lean-prepared simulation, normal
continuation afterwards, mixed batches, public plan explanation and graph view.
Source execution uses cold rich snapshots; it is not a native performance arm.
"""
function lean_inspection_checks()
    reports = Any[]
    @testset "Lean plans preserve readable source and inspection APIs" begin
        for outputs in (:none, :all)
            control = PSE.run!(_fixture(false); steps=0, outputs)
            candidate = Lean.prepare_lean(_fixture(true); steps=0, outputs)
            before = Lean.lean_report(candidate)
            @test before.skipped_rich_targets == 2
            @test before.constructed_rich_targets == 1
            @test before.lazy_target_snapshots == 0
            @test before.live_lean_batches == 1
            explanation = PSE.Diagnostics.explain_execution_plan(candidate)
            @test length(explanation) == 2
            @test sum(row -> row.batch_size, explanation) == 3
            @test Lean.lean_report(candidate).lazy_target_snapshots == 0
            graph = PSE.model_graph_view(candidate.compiled; level=:resolved)
            @test isempty(graph.diagnostics)
            @test length(graph.applications) == 2
            @test Lean.lean_report(candidate).lazy_target_snapshots == 0
            # The first step really runs native columns. Following steps use
            # the emitted ordinary kernel bodies over on-demand rich snapshots.
            PSE.continue!(control; steps=1)
            PSE.continue!(candidate; steps=1)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            @test Lean.lean_report(candidate).native_row_executions == 2
            source = PSE.Authoring.compiled_model_source(candidate;
                function_name=:lean_readable_model!)
            @test occursin("function lean_readable_model!", source)
            generated_module = Module(gensym(:LeanReadableSource))
            Base.include_string(generated_module, source, "lean-readable-source-model.jl")
            generated_run = Core.eval(generated_module, :lean_readable_model!)
            Base.invokelatest(generated_run, candidate; steps=2)
            PSE.continue!(control; steps=2)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            @test Lean.lean_report(candidate).lazy_target_snapshots == 4
            @test Lean.lean_report(candidate).native_row_executions == 2
            # Normal execution resumes the exact schedule/history and reuses
            # canonical references after readable-source execution.
            PSE.continue!(candidate; steps=1)
            PSE.continue!(control; steps=1)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            @test Lean.lean_report(candidate).native_row_executions == 4
            @test PSE.final_state(candidate, 1).value === 24.0f0
            @test PSE.final_state(candidate, 3).observed === 48.0f0
            @test PSE.final_state(candidate, 3).visits == 4
            push!(reports, (; outputs, passed=true, report=Lean.lean_report(candidate),
                generated_source_bytes=sizeof(source)))
        end
    end
    return (; passed=true, reports, generated_execution=:ordinary_on_demand_snapshots,
        qualification=:readable_source_public_inspection_and_mixed_execution)
end

end # module
