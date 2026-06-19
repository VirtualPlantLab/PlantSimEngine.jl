# The Scene/Object API is one public compiler and runtime. Internal ownership is
# split by dependency direction; these files are not modules and add no public
# abstraction boundary.
include("scene_object/registry_topology.jl")
include("scene_object/selectors.jl")
include("scene_object/compilation.jl")
include("scene_object/environment_bindings.jl")
include("scene_object/runtime_outputs.jl")
include("scene_object/scenario_dsl.jl")
