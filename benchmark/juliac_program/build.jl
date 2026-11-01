# Run by include through a Kaimon session for buildenv/, never launch Julia directly.
using JuliaC

function install_launcher!(destination)
    launcher = joinpath(destination,"bin","run-pse-program")
    cp(joinpath(@__DIR__,"launcher.sh"),launcher;force=true)
    chmod(launcher,0o755)
    return launcher
end

function build_native(; output_root=get(ENV,"PSE_NATIVE_BUILD_DIR",joinpath(@__DIR__,"build")))
    mkpath(output_root)
    # PackageCompiler does not overwrite bundled artifact directories. Each build
    # gets a fresh destination, and a failed build leaves the prior bundle intact.
    destination = mktempdir(output_root;prefix="bundle-")
    image = ImageRecipe(file=joinpath(@__DIR__,"app"),output_type="--output-exe",
        trim_mode="safe",cpu_target="generic",verbose=false,quiet=true)
    compilation_s = @elapsed compile_products(image)
    link = LinkRecipe(image_recipe=image,outname=joinpath(destination,"pse_program"),rpath="@bundle")
    link_s = @elapsed link_products(link)
    bundle_s = @elapsed bundle_products(BundleRecipe(link_recipe=link,output_dir=destination))
    install_launcher!(destination)
    write(joinpath(output_root,"latest.txt"),destination*"\n")
    result = (julia=string(VERSION),juliac=string(pkgversion(JuliaC)),trim=image.trim_mode,
        cpu=image.cpu_target,compilation_s,link_s,bundle_s,bundle=destination)
    open(joinpath(destination,"build.toml"),"w") do io
        JuliaC.TOML.print(io,Dict(string(k)=>v for (k,v) in pairs(result)))
    end
    return result
end
build_native()
