# Include/run only through Kaimon in the isolated buildenv project.
using JuliaC
using SHA
using TOML
function build_amap_registry(;project="/private/tmp/pse-juliac-large-20261102/amap-native-app",
    destination=mktempdir("/private/tmp";prefix="amap-registry-bundle-"))
    entry=joinpath(@__DIR__,"downstream_amapsim_native_main.jl")
    mkpath(destination)
    image=JuliaC.ImageRecipe(file=entry,project=project,output_type="--output-exe",
        trim_mode="safe",cpu_target="generic",verbose=false,quiet=true)
    compilation_s=@elapsed open(joinpath(destination,"compile.log"),"w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                JuliaC.compile_products(image)
            end
        end
    end
    link=JuliaC.LinkRecipe(image_recipe=image,outname=joinpath(destination,"pse_program"),rpath="@bundle")
    link_s=@elapsed JuliaC.link_products(link)
    bundle_s=@elapsed JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link,output_dir=destination))
    launcher=joinpath(destination,"bin","run-pse-program")
    cp(joinpath(@__DIR__,"launcher.sh"),launcher;force=true);chmod(launcher,0o755)
    for name in ("Project.toml","Manifest.toml")
        cp(joinpath(image.instantiated_project,name),joinpath(destination,name);force=true)
    end
    files=("downstream_amapsim_native_main.jl","downstream_amapsim_native_entry.jl",
        "downstream_amapsim_native_codec.jl","downstream_amapsim_fixture.jl",
        "downstream_amapsim_bridge.jl","app/src/object_program.jl","downstream_amapsim_typing.py")
    source_hashes=Dict(name=>bytes2hex(sha256(read(joinpath(@__DIR__,name)))) for name in files)
    open(joinpath(destination,"entry_sources.toml"),"w") do io
        TOML.print(io,source_hashes;sorted=true)
    end
    cp(joinpath(@__DIR__,"downstream_amapsim_typing.json"),joinpath(destination,"source-typing.json");force=true)
    cp(joinpath(@__DIR__,"downstream_amapsim_adapter_typing.patch"),joinpath(destination,"source-typing.patch");force=true)
    result=(julia=string(VERSION),juliac=string(Base.pkgversion(JuliaC)),trim="safe",cpu="generic",
        compilation_s,link_s,bundle_s,bundle=destination,
        binary_sha256=bytes2hex(sha256(read(joinpath(destination,"bin","pse_program")))))
    open(joinpath(destination,"build.toml"),"w") do io
        TOML.print(io,Dict(string(k)=>v for (k,v) in pairs(result)))
    end
    return result
end
