# Include through a Kaimon session in the isolated JuliaC build environment.
using JuliaC, SHA, TOML
isdefined(@__MODULE__,:DownstreamMAESPAPSESources) || include(joinpath(@__DIR__,"downstream_maespa_pse_sources.jl"))
const MAESPA_BUILD_IMAGES=Dict{String,Any}()
const MAESPA_BUILD_LINKS=Dict{String,Any}()

function _maespa_build_stage(destination,stage;details=NamedTuple())
    record=Dict{String,Any}("stage"=>String(stage),"updated_unix"=>time())
    for (key,value) in pairs(details)
        record[String(key)]=value
    end
    temporary=joinpath(destination,"stage.toml.tmp")
    open(io->TOML.print(io,record),temporary,"w")
    mv(temporary,joinpath(destination,"stage.toml");force=true)
    return nothing
end

function build_maespa_registry(;project="/private/tmp/pse-juliac-large-20261102/maespa-native-app",
        source_root="/private/tmp/pse-juliac-large-20261102/typed-sources/MAESPA",
        profile=:daylight,
        destination=mktempdir("/private/tmp";prefix="maespa-registry-bundle-"))
    entry=joinpath(@__DIR__,"maespa_native_main.jl")
    profile in (:daylight,:matrix) || throw(ArgumentError("unknown MAESPA build profile"))
    mkpath(destination)
    pse_source=DownstreamMAESPAPSESources.snapshot()
    DownstreamMAESPAPSESources.write_snapshot(joinpath(destination,"pse_source_expected.json"),pse_source)
    files=("maespa_native_main.jl","downstream_maespa_fixture.jl","downstream_maespa_encoding.jl",
        "app/src/registry_program.jl","app/src/registry_program_output.jl",
        "app/src/registry_program_display.jl",
        "app/src/object_program_maespa_environment.jl","app/src/typed_seed_copy.jl",
        "downstream_maespa_build.jl","downstream_maespa_pse_sources.jl","downstream_maespa_typing.py",
        "downstream_maespa_runtime_typing.py","downstream_maespa_closed_fields.py","downstream_maespa_leaf_outputs.py",
        "downstream_maespa_typing.json","downstream_maespa_typing.patch")
    hashes=Dict(name=>bytes2hex(sha256(read(joinpath(@__DIR__,name)))) for name in files)
    for name in files
        copied=joinpath(destination,"entry_sources",name)
        mkpath(dirname(copied));cp(joinpath(@__DIR__,name),copied;force=true)
    end
    image=JuliaC.ImageRecipe(file=entry,project=project,output_type="--output-exe",
        trim_mode="safe",cpu_target="generic",verbose=false,quiet=true)
    MAESPA_BUILD_IMAGES[abspath(destination)]=image
    _maespa_build_stage(destination,:compile;details=(;entry,project,profile=String(profile),source_root,
        instantiated_project=string(image.instantiated_project)))
    compilation_s=@elapsed open(joinpath(destination,"compile.log"),"w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                withenv("PSE_MAESPA_PATH"=>source_root,"PSE_MAESPA_BUILD_DIR"=>destination,
                        "PSE_MAESPA_BUILD_PROFILE"=>String(profile)) do
                    JuliaC.compile_products(image)
                end
            end
        end
    end
    all(name->bytes2hex(sha256(read(joinpath(@__DIR__,name))))==hashes[name],files) ||
        error("native entry sources changed during compilation")
    DownstreamMAESPAPSESources.verify_unchanged(pse_source)
    DownstreamMAESPAPSESources.verify_archived(joinpath(destination,"pse_source_snapshot.json");
        current=pse_source,expected_aggregate=pse_source.aggregate_sha256)
    _maespa_build_stage(destination,:link;details=(;compilation_s))
    link=JuliaC.LinkRecipe(image_recipe=image,outname=joinpath(destination,"pse_program"),rpath="@bundle")
    MAESPA_BUILD_LINKS[abspath(destination)]=link
    link_s=@elapsed JuliaC.link_products(link)
    _maespa_build_stage(destination,:bundle;details=(;compilation_s,link_s))
    bundle_s=@elapsed JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link,output_dir=destination))
    launcher=joinpath(destination,"bin","run-pse-program")
    cp(joinpath(@__DIR__,"launcher.sh"),launcher;force=true);chmod(launcher,0o755)
    for name in ("Project.toml","Manifest.toml")
        cp(joinpath(image.instantiated_project,name),joinpath(destination,name);force=true)
    end
    open(joinpath(destination,"entry_sources.toml"),"w") do io
        TOML.print(io,hashes;sorted=true)
    end
    for (source,target) in (("downstream_maespa_typing.json","source-typing.json"),
            ("downstream_maespa_typing.patch","source-typing.patch"))
        cp(joinpath(@__DIR__,source),joinpath(destination,target);force=true)
    end
    case_count=profile===:daylight ? 1 : 8
    construction_hashes=Dict("construction-rng-$index.json"=>bytes2hex(sha256(read(joinpath(destination,"construction-rng-$index.json"))))
        for index in 1:case_count)
    open(joinpath(destination,"construction_rngs.toml"),"w") do io
        TOML.print(io,construction_hashes;sorted=true)
    end
    DownstreamMAESPAPSESources.verify_unchanged(pse_source)
    result=(format_version=1,julia=string(VERSION),juliac=string(Base.pkgversion(JuliaC)),trim="safe",cpu="generic",source_root,
        profile=String(profile),case_count,
        host_recipe_recovered=false,compilation_s_available=true,
        compilation_s,link_s,bundle_s,bundle=destination,
        binary_sha256=bytes2hex(sha256(read(joinpath(destination,"bin","pse_program")))),
        launcher_sha256=bytes2hex(sha256(read(launcher))),
        entry_manifest_sha256=bytes2hex(sha256(read(joinpath(destination,"entry_sources.toml")))),
        source_typing_sha256=bytes2hex(sha256(read(joinpath(destination,"source-typing.json")))),
        source_patch_sha256=bytes2hex(sha256(read(joinpath(destination,"source-typing.patch")))),
        project_sha256=bytes2hex(sha256(read(joinpath(destination,"Project.toml")))),
        manifest_sha256=bytes2hex(sha256(read(joinpath(destination,"Manifest.toml")))),
        construction_manifest_sha256=bytes2hex(sha256(read(joinpath(destination,"construction_rngs.toml")))),
        case_manifest_sha256=bytes2hex(sha256(read(joinpath(destination,"native_cases.json")))),
        pse_source_sha256=pse_source.aggregate_sha256,
        pse_source_expected_sha256=bytes2hex(sha256(read(joinpath(destination,"pse_source_expected.json")))),
        pse_source_snapshot_sha256=bytes2hex(sha256(read(joinpath(destination,"pse_source_snapshot.json")))),
        scientific_source_sha256=chomp(read(joinpath(destination,"source_snapshot_sha256.txt"),String)))
    open(joinpath(destination,"build.toml"),"w") do io
        TOML.print(io,Dict(string(key)=>value for (key,value) in pairs(result)))
    end
    _maespa_build_stage(destination,:complete;details=(;compilation_s,link_s,bundle_s))
    return result
end
