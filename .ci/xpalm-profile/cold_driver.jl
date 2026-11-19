include("science_control.jl")
include("cold_phase.jl")
const OUT, ROLE = ARGS
@assert ROLE == "candidate"
mkpath(OUT)
@test VERSION == v"1.13.3"
@test Threads.nthreads(:default) == 1 && Threads.ngcthreads() == 1
@test realpath(pkgdir(PSE)) == realpath(joinpath(ENVIRONMENT, "..", "PlantSimEngine"))
@test realpath(pkgdir(R.XPalm)) == realpath(joinpath(ENVIRONMENT, "..", "XPalm"))
# The CLI compilation stream and these explicit phase markers share the same fd.
# The filter records bounded scalars and simple names, never argument signatures.
open("/dev/fd/3", "w") do phase_io
    source = @cold_phase(phase_io, :construction, R._construct())
    initial_rng = model_rngs(source)
    sim = @cold_phase(phase_io, :preparation, R._prepare(source, DAYS, :none))
    @test model_rngs(source) == initial_rng
    @cold_phase(phase_io, :first_full_execution, PSE.continue!(sim; steps=DAYS))
    observed = science(sim, source)
    report = (; role=ROLE, cpu=Sys.CPU_NAME, julia=string(VERSION),
        julia_commit=Base.GIT_VERSION_INFO.commit, science=observed,
        trace_enabled=true, measured_performance=false,
        timing_scope="separate cold process with compiler tracing; diagnostic overhead is included; not comparable benchmark timings")
    write(joinpath(OUT, "candidate-cold.json"), PSE.JSON.json(report))
end
