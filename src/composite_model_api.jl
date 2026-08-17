# The Composite Model/Object API is one public compiler and runtime. Internal ownership is
# split by dependency direction; these files are not modules and add no public
# abstraction boundary.
include("composite_model/registry_topology.jl")
include("composite_model/selectors.jl")
include("composite_model/compilation.jl")
include("composite_model/environment_bindings.jl")
include("composite_model/runtime_outputs.jl")
include("composite_model/scenario_dsl.jl")
