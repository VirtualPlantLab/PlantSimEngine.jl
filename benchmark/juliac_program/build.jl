# Run by include through a Kaimon session for buildenv/, never launch Julia directly.
using JuliaC
const APP_PROJECT = joinpath(@__DIR__, "app")
const BUILD_DIR = get(ENV, "PSE_NATIVE_BUILD_DIR", joinpath(@__DIR__, "build"))
image = ImageRecipe(file=APP_PROJECT, output_type="--output-exe",
    trim_mode="safe", cpu_target="generic", verbose=true)
compile_products(image)
link = LinkRecipe(image_recipe=image, outname=joinpath(BUILD_DIR, "pse_program"), rpath="@bundle")
link_products(link)
bundle_products(BundleRecipe(link_recipe=link, output_dir=BUILD_DIR))
