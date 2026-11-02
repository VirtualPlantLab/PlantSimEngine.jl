# JuliaC script entries expose @main in Main; keep the reusable entry namespaced.
include("downstream_amapsim_native_entry.jl")
function (@main)(args::Vector{String})
    return AMAPRegistryApp.main(args)
end
