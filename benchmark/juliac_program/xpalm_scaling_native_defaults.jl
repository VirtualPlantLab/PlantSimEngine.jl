# Host-side copied-app builder. Include/run through Kaimon with JuliaC loaded;
# no changes are made to the qualified app, standard bundle or latest pointer.
isdefined(@__MODULE__, :FullXPalmNativePerformance) || include(joinpath(@__DIR__, "full_xpalm_native_performance.jl"))

module XPalmScalingNativeDefaults

using SHA
using TOML
using XPalm
import ..FullXPalmNativePerformance as NP

const DEFAULT_HELPERS = raw"""
# Exact package parameters are imported only at authoring/build time. In
# particular, do not call FullXPalmFixture.parameters/palm: they replace both
# phyllochron endpoints and may shorten phenology or change RNG seeds.
function _package_default_full_setup()
    parameters=FullXPalmFixture.XPalm.default_parameters()
    palm=FullXPalmFixture.XPalm.Palm(;initiation_age=0,parameters,architecture=false)
    applications=FullXPalmFixture.specs(palm)
    return (palm=palm,applications=applications,models=FullXPalmFixture.models(applications),
        topology=FullXPalmFixture.topology_descriptor(palm),
        initial=FullXPalmFixture.initial_data(palm,applications))
end
const FULL_PACKAGE_DEFAULT_SETUP=_package_default_full_setup()
const FULL_PACKAGE_DEFAULT_PROGRAM=ReusableProgram.prepare(FullXPalmFixture.preparation_scene(FULL_PACKAGE_DEFAULT_SETUP);
    initial=FULL_PACKAGE_DEFAULT_SETUP.initial.templates)

function simulate_package_defaults(days::Int,retain::Bool)
    days>=0 || throw(ArgumentError("negative full-XPalm duration"))
    setup=FULL_PACKAGE_DEFAULT_SETUP
    models=ReusableProgram._schema_map(model->model,setup.models)
    state=ReusableProgram.instantiate(FULL_PACKAGE_DEFAULT_PROGRAM,models,_full_native_tree(setup.topology);
        initial=setup.initial.templates,objects=setup.initial.objects,retain)
    constants=FullXPalmFixture.PSE.Constants()
    for row in FullXPalmFixture.rows(days)
        ReusableProgram.step!(state,row;constants)
    end
    return state
end

# Match the existing native timer/GC/output protocol exactly. P0 is warmup,
# every trial instantiates fresh owned model/RNG/status/topology, and only the
# final result is serialized after stopping its internal timer.
Base.@noinline function _perf_package_defaults_trial(i::Int,days::Int,retain::Bool,show_result::Bool)
    GC.gc()
    start=time_ns()
    state=simulate_package_defaults(days,retain)
    elapsed=time_ns()-start
    _full_print_record(("P",i,elapsed,length(state.nodes),state.step))
    show_result && _print_full_xpalm(state)
    return nothing
end

"""

const DEFAULT_BRANCH = raw"""
    if mode=="perfdefaults"
        length(args)==4 || throw(ArgumentError("perfdefaults days repeats retain"))
        days=parse(Int,args[2]); repeats=parse(Int,args[3]); retain=parse(Bool,args[4])
        repeats>0 || throw(ArgumentError("positive repeats required"))
        for i in 0:repeats
            _perf_package_defaults_trial(i,days,retain,i==repeats)
        end
        return 0
    end
"""

function _instrument_defaults!(entry)
    source=read(entry,String)
    occursin("FULL_PACKAGE_DEFAULT_SETUP",source) && error("copied app already contains the defaults entry")
    main_marker="function (@main)(args::Vector{String})"
    mode_marker="    mode = args[1]\n"
    length(findall(main_marker,source))==1 || error("cannot identify the unique native main entry")
    length(findall(mode_marker,source))==1 || error("cannot identify the unique native mode parser")
    source=replace(source,main_marker=>DEFAULT_HELPERS*main_marker;count=1)
    source=replace(source,mode_marker=>mode_marker*DEFAULT_BRANCH;count=1)
    write(entry,source)
    return entry
end

"""
    defaults_command(executable, settings, repeats) -> Cmd

Command factory for `XPalmScaling.compare_scaling(...;
profile=:package_defaults, native_command=defaults_command)`. The executable
must come from `build_native_defaults`. Its CLI accepts `perfdefaults days
repeats retain`, without any single-rate override or phenology toggle.
"""
function defaults_command(executable,settings,repeats)
    settings.profile===:package_defaults || throw(ArgumentError("defaults_command requires profile=:package_defaults"))
    return Cmd([abspath(executable),"perfdefaults",string(settings.days),string(repeats),string(settings.retain)])
end

"""
    build_native_defaults(; bundle=nothing, app_directory=nothing)

Build a fresh temporary copy of the current app with both the established
`perffull` timer and a `perfdefaults` entry. Reuse the copied-app path rebasing,
launcher, JuliaC safe trimming and generic CPU recipe of
`FullXPalmNativePerformance`; do not change the standard app/build/latest.
Explicit app/bundle destinations must be fresh and disjoint. Artifacts and
the instrumented source remain available for caller-controlled inspection.

`perfdefaults` authors original XPalm.Palm/model_applications from untouched
XPalm.default_parameters(): the pinned package's initial/mature phyllochron
endpoints remain unequal (0.0111/0.0074), and its phenology/RNG defaults remain
unchanged. Architecture=false and initiation_age=0 are explicit constructor
choices. Forcing is still the common synthetic FullXPalmFixture.rows data.
Native runtime only instantiates the prepared original scientific models and
executes them; it does not load parameters or construct a Palm/ModelSpec.

Every native process emits a P0 warmup, requested timed trials and final
F/T/S/O/R records. Retention supports all/none. Timers exclude startup,
explicit GC, printing and host validation; they include fresh simulation
instantiation, Constants/forcing construction and daily execution.

Call through Kaimon with Main.JuliaC loaded (for example, add the existing
buildenv to LOAD_PATH in the app session). Then use:

```julia
include("../xpalm_scaling_native_defaults.jl")
built = XPalmScalingNativeDefaults.build_native_defaults()
result = XPalmScaling.compare_scaling(previous, current;
    days=256, profile=:package_defaults, retain=false,
    native_bundle=built.bundle, native_checks=FullXPalmNativeChecks,
    native_command=XPalmScalingNativeDefaults.defaults_command)
```

A successful build establishes compilation only. Scientific/native timing
qualification requires the scaling harness's full ordinary-PSE parity gate.
"""
function build_native_defaults(;bundle=nothing,app_directory=nothing)
    isdefined(Main,:JuliaC) || error("load JuliaC in the calling Kaimon session before building")
    juliac=getfield(Main,:JuliaC)
    source_app=joinpath(@__DIR__,"app")
    standard_build=joinpath(@__DIR__,"build")
    scratch=(isnothing(bundle)||isnothing(app_directory)) ? mktempdir(prefix="pse-native-defaults-") : nothing
    destination=NP._fresh_destination(isnothing(bundle) ? joinpath(scratch,"bundle") : bundle,source_app,standard_build)
    app=NP._fresh_destination(isnothing(app_directory) ? joinpath(scratch,"app") : app_directory,source_app,standard_build)
    (NP._within(destination,app)||NP._within(app,destination)) && error("app and bundle destinations overlap")
    mkpath(dirname(app))
    cp(source_app,app)
    NP._rebase_paths!(app,source_app)
    entry=NP._instrument!(app)
    _instrument_defaults!(entry)
    mkpath(destination)
    image=juliac.ImageRecipe(file=app,output_type="--output-exe",
        trim_mode="safe",cpu_target="generic",verbose=false,quiet=true)
    compilation_s=@elapsed open(joinpath(destination,"compile.log"),"w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                juliac.compile_products(image)
            end
        end
    end
    link=juliac.LinkRecipe(image_recipe=image,outname=joinpath(destination,"pse_program"),rpath="@bundle")
    link_s=@elapsed juliac.link_products(link)
    bundle_s=@elapsed juliac.bundle_products(juliac.BundleRecipe(link_recipe=link,output_dir=destination))
    launcher=joinpath(destination,"bin","run-pse-program")
    cp(joinpath(@__DIR__,"launcher.sh"),launcher;force=true)
    chmod(launcher,0o755)
    parameters=XPalm.default_parameters()
    result=(julia=string(VERSION),juliac=string(Base.pkgversion(juliac)),xpalm=string(Base.pkgversion(XPalm)),
        trim=image.trim_mode,cpu=image.cpu_target,compilation_s=compilation_s,link_s=link_s,bundle_s=bundle_s,
        bundle=destination,app_directory=app,performance_entry=true,package_default_entry=true,
        package_parameters_untouched=true,phyllochron_initial=parameters["phyllochron"]["production_speed_initial"],
        phyllochron_mature=parameters["phyllochron"]["production_speed_mature"],
        source_revision=NP._source_revision(normpath(joinpath(@__DIR__,"..",".."))),
        app_sha256=bytes2hex(sha256(read(entry))),
        binary_sha256=bytes2hex(sha256(read(joinpath(destination,"bin","pse_program")))))
    open(joinpath(destination,"build.toml"),"w") do io
        TOML.print(io,Dict(string(key)=>value for (key,value) in pairs(result)))
    end
    return result
end

end # module XPalmScalingNativeDefaults
