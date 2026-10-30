module PureJuliaBoundariesChecks

using PlantSimEngine, SHA, Test
const PSE = PlantSimEngine
const Pure = Main.PureJuliaReference
const Boundaries = Main.PureJuliaBoundaries
const PBDriver = Main.NativePBDriver
const CR = Main.CompiledRegionsExperiment

export noinline_pb_checks, noinline_work_check

function noinline_pb_checks(; nobjects::Int=2, steps::Int=2)
    fixture = Pure.plain_pb_fixture(; nobjects, steps)
    inline = Pure.prepare_pure_pb(fixture; count_calls=false)
    noinline = Pure.prepare_pure_pb(fixture; count_calls=false)
    counted = Pure.prepare_pure_pb(fixture; count_calls=true)
    reference = PSE.run!(PBDriver.pb_native_fixture(;
        native=false, nobjects, steps).model; steps=0, outputs=:none)
    expected_photosynthesis = 0
    @testset "Original PB task with controlled noinline child boundaries" begin
        @test inline.counts === noinline.counts === nothing
        @test typeof(first(inline.rows)) === typeof(first(noinline.rows))
        @test isequal(Pure.pure_pb_snapshot(inline), CR.portable_downstream_snapshot(reference))
        @test repr(Pure.pure_pb_snapshot(noinline)) == repr(CR.portable_downstream_snapshot(reference))
        for step in 1:steps
            PSE.step!(reference)
            Pure.advance_pure_pb!(inline; steps=1)
            Boundaries.advance_pure_noinline_pb!(noinline; steps=1)
            Boundaries.advance_pure_noinline_pb!(counted; steps=1)
            expected = CR.portable_downstream_snapshot(reference)
            @test isequal(Pure.pure_pb_snapshot(inline), expected)
            @test isequal(Pure.pure_pb_snapshot(noinline), expected)
            @test isequal(Pure.pure_pb_snapshot(counted), expected)
            @test repr(Pure.pure_pb_snapshot(noinline)) == repr(expected)
            # The snapshot stores every field's value and precise scalar type.
            expected_photosynthesis += sum(min(fixture.models.energy.maxiter,
                PSE.final_state(reference, index).iter + 1) for index in 1:nobjects)
            actual = Pure.pure_pb_report(counted).work
            @test actual.roots == nobjects * step
            @test actual.photosynthesis == expected_photosynthesis
            @test actual.stomata == expected_photosynthesis
            @test actual.model_lookups == expected_photosynthesis
        end
        context = Boundaries.NoInlinePlainPBContext(noinline.models,
            first(noinline.rows), noinline.constants, noinline.counts)
        @test_throws ArgumentError PSE.run_call!(context, :photosynthesis;
            sampled_environment=fixture.weather[1], publish=true)
    end
    return (passed=true, nobjects, steps, counted_work=Pure.pure_pb_report(counted).work,
        qualification=:same_flat_state_original_kernels_only_child_boundary_changed)
end

"""
    noinline_work_check(; nobjects=32, steps=128, expected_digest=nothing)

One cheap counted companion run per boundary, not a timing sample. It checks
the full forcing cycle, exact final scientific digest and actual iterative
kernel counts. Pass the existing numerical screen's expected_digest to tie
the work audit to that benchmark without adding counters to its timed loop.
"""
function noinline_work_check(; nobjects::Int=32, steps::Int=128,
    expected_digest=nothing)
    fixture = Pure.plain_pb_fixture(; nobjects, steps)
    inline = Pure.prepare_pure_pb(fixture; count_calls=true)
    noinline = Pure.prepare_pure_pb(fixture; count_calls=true)
    Pure.advance_pure_pb!(inline; steps)
    Boundaries.advance_pure_noinline_pb!(noinline; steps)
    inline_snapshot, noinline_snapshot = Pure.pure_pb_snapshot(inline), Pure.pure_pb_snapshot(noinline)
    inline_digest = bytes2hex(sha256(repr(inline_snapshot)))
    noinline_digest = bytes2hex(sha256(repr(noinline_snapshot)))
    inline_work, noinline_work = Pure.pure_pb_report(inline).work, Pure.pure_pb_report(noinline).work
    @testset "Counted PB boundary companions match numerical benchmark work" begin
        @test isequal(inline_snapshot, noinline_snapshot)
        @test inline_digest == noinline_digest
        @test inline_work == noinline_work
        @test inline_work.roots == nobjects * steps
        @test inline_work.photosynthesis == inline_work.stomata == inline_work.model_lookups
        expected_digest === nothing || (@test inline_digest == expected_digest)
    end
    return (passed=true, nobjects, steps, digest=inline_digest,
        inline_work, noinline_work,
        interpretation=:counted_companion_not_runtime_measurement)
end

end # module
