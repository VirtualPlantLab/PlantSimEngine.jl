"""
    init_mtg_models!(
        mtg::MultiScaleTreeGraph.Node,
        models::Dict{String,<:ModelList},
        i=nothing;
        verbose=true,
        attr_name=Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models")),
    )

initialize the components of an MTG (*i.e.* nodes) with the corresponding models.

The function checks if the models associated to each component of the MTG are fully initialized,
and if not, tries to initialize the variables using the MTG attributes with the exact same name,
and if not found, returns an error.

# Arguments

- `mtg::MultiScaleTreeGraph.Node`: the MTG tree.
- `models::Dict{String,ModelList}`: a dictionary of models named by components names
- `i=nothing`: the time-step to initialize. If `nothing`, initialize all the time-steps.
- `verbose = true`: return information during the processes
- `attr_name = Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models"))`: the node attribute name used to store the models, default to 
Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models"))

# Examples

```@example
using PlantSimEngine, MultiScaleTreeGraph

# Including example processes and models:
using PlantSimEngine.Examples;

# Make an MTG:
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
leaf[:var1] = [15.0, 16.0]
leaf[:var2] = 0.3

# Declare our models:
models = Dict(
    "Leaf" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    )
)

# Checking which variables are needed for our models:
[component => to_initialize(model) for (component, model) in models]
# OK we need to initialize :var1 and :var2

# We could compute them directly inside the MTG from available variables instead of 
# giving them as initialisations:
transform!(
    mtg,
    :var1 => (x -> x .+ 2.0) => :var2,
    ignore_nothing = true
)

# Initialising all components with their corresponding models and initialisations at time-step 1:
init_mtg_models!(mtg, models, 1)
```
Note that this is possible only because the initialisation values are found in the MTG.
If the initialisations are constant values between components, we can directly initialize
them in the models definition (as we do in the begining).
"""
function init_mtg_models!(
    mtg,
    models::Dict{String,<:ModelList},
    nsteps;
    verbose=true,
    attr_name=Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models")),
    force=false
)
    error(
        "The function `init_mtg_models!` is not implemented for the type $(typeof(mtg)).",
        ". At the moment, only `MultiScaleTreeGraph.Node` with `Dict` attributes are supported."
    )
end

function init_mtg_models!(
    mtg::MultiScaleTreeGraph.Node{N,A},
    models::Dict{String,<:ModelList},
    nsteps;
    verbose=true,
    attr_name=Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models")),
    force=false
) where {N<:MultiScaleTreeGraph.AbstractNodeMTG,A<:AbstractDict}

    attr_name_sym = Symbol(attr_name)
    # Check if all components have a model
    component_no_models = setdiff(MultiScaleTreeGraph.components(mtg), keys(models))
    if verbose && length(component_no_models) > 0
        @info string("No model found for component(s) ", join(component_no_models, ", ", ", and ")) maxlog = 1
    end

    # Get the variables in the models that has values that are not initialized:
    to_init = Dict{String,Set{Symbol}}()
    for (key, value) in models
        inits = to_initialize(value)
        vars = Set{Symbol}()
        for init_ in inits
            for j in init_
                push!(vars, j)
            end
        end
        if length(vars) > 0
            push!(to_init, key => vars)
        end
    end

    # If some values need initialisation, check first if they are found as MTG attributes, and if they do, use them:
    attrs_missing = Dict{String,Set{Symbol}}()

    MultiScaleTreeGraph.traverse!(mtg) do node
        # If the component has models associated to it
        # node = get_node(mtg, 3)
        if haskey(models, node.MTG.symbol)
            # Search if any variable is missing from the models *and* the attributes:
            attr_not_found = setdiff(
                to_init[node.MTG.symbol],
                collect(keys(node.attributes))
            )

            # If not, pre-allocate the node attributes with missing variables:
            if length(attr_not_found) == 0
                # Get the status of the model (needed variables for the simulation):
                st = status(models[node.MTG.symbol])
                # Get the variables that should be taken from the input models (already initialized):
                vars_default = setdiff(keys(st), to_init[node.MTG.symbol])

                # Put the default values found in the models' status into the attributes:
                for var in vars_default
                    # var = :var4
                    # Make a copy of the default value:
                    default_value = copy(models[node.MTG.symbol][var])

                    # If the value already exist but is not an array, make an array out of it.
                    # This happens when dealing with variables initialized with only one value.
                    if length(default_value) == 1 && nsteps > 1
                        default_value = fill(default_value[1], nsteps)
                    end

                    # If the variable is already defined in the node, is different than default_value, and we don't force overwrite, raise an error:
                    if !force && node[var] !== nothing && node[var] != default_value
                        error("The attribute $(var) is already defined in node $(node.id). Remove it from the `models` or set `force=true`.")
                    end

                    # If the default models only have one time-sep, we'll reference it for all time-steps. Otherwise, we use the time-step value.
                    # Check if we don't go out of bounds:
                    if length(default_value) > 1 && nsteps > length(default_value)
                        error("The default value for $(var) in `models` for $(node.MTG.symbol) type is only defined for $(length(default_value)) time-steps, you required $(nsteps).")
                    end

                    node[var] = default_value
                end

                # Pre-allocate the warning information if a variable is found but has length == 1 and is changed to length nsteps:
                verbose && (attr_one_value = Symbol[])

                # Pre-allocate the node attributes for all time-step:
                for var in keys(st)
                    # var = :var2
                    if node[var] === nothing
                        # If the attribute does not exist, create a vector of n-steps values
                        node[var] = fill(st[var], nsteps)
                    elseif typeof(node[var]) <: AbstractArray
                        # If it does exist and is already an n-steps array, do nothing
                        length(node[var]) == nsteps && continue

                        if length(node[var]) != 1
                            error("Attribute $var is already stored in node $(node.id) but as length",
                                "!= number of steps to simulate ($nsteps).")
                        end

                        if !force
                            error("The attribute $(var) is already defined in node $(node.id) but has length != nsteps ($nsteps). Update it or set `force=true`.")
                        elseif verbose
                            push!(attr_one_value, var) # Store the variable name for the warning message at the end (return all variables at once)
                        end

                        node[var] = fill(node[var], nsteps)
                    else
                        # If the value already exist but is not an array, make an array out of it.
                        # This happens when dealing with variables initialized with only one value.
                        if !force && length(node[var]) > 1
                            error("The attribute $(var) is already defined in node $(node.id) but has length != nsteps ($nsteps). Update it or set `force=true`.")
                        elseif verbose
                            push!(attr_one_value, var) # Store the variable name for the warning message at the end (return all variables at once)
                        end
                        node[var] = fill(node[var], nsteps)
                    end
                end

                if verbose && length(attr_one_value) > 0
                    @info "The attributes $(attr_one_value) were already defined in node $(node.id) but had length == 1. Extending it to nsteps ($nsteps)." maxlog = 3
                end

                # Initialize the ModelList using attributes:
                # as_default = NamedTuple(begin
                #     # if the default models only have one time-sep, we use it for all time-steps. Otherwise, we use the time-step value.
                #     default_value = models[node.MTG.symbol][var]
                #     # Check if we don't go out of bounds:
                #     if length(default_value) > 1 && i > length(default_value)
                #         error("The default value for $(var) in `models` for $(node.MTG.symbol) type is not defined for time-step $(i) and is not a constant value. Please provide one time-sep, or $i.")
                #     end
                #     i_var = length(default_value) > 1 ? i : 1
                #     var => get_Ref_attr(default_value, i_var)
                # end for var in vars_default)

                # Finally, use references to the attributes values as the status of the ModelList:
                node[attr_name_sym] =
                    copy(
                        models[node.MTG.symbol],
                        TimeStepTable([
                            Status(NamedTuple(var => get_Ref_i(node, var, i) for var in keys(st))) for i in 1:nsteps
                        ])
                    )
            else
                # If some initialisations are not available from the node attributes:
                if length(attr_not_found) > 0
                    for i in attr_not_found
                        !haskey(attrs_missing, node.MTG.symbol) && (attrs_missing[node.MTG.symbol] = Set{Symbol}())
                        push!(attrs_missing[node.MTG.symbol], i)
                    end
                end
            end
        end
    end
    if any([length(value) > 0 for (key, value) in attrs_missing])
        err_msg = [string("\n", key, ": [", join(value, ", ", " and "), "]") for (key, value) in attrs_missing]
        error(
            string(
                "Some variables need to be initialized for some components before simulation:",
                join(err_msg, ", ", " and ")
            )
        )
    end

    return to_init
end

"""
    get_Ref_i(node, attr, i<:Nothing)
    get_Ref_i(node, attr, i)

Get reference to node attribute at ith value or value if `i<:Nothing`.
"""
function get_Ref_i(node, attr, i::T) where {T<:Nothing}
    Ref(node[attr])
end

function get_Ref_i(node, attr, i)
    node_attr = node[attr]
    # Throw a bound error if the index is out of bounds:
    length(node_attr) >= i || error("Indexing out of bounds for attribute $attr in node $(node.id)")

    get_Ref_attr(node_attr, i)
end

function get_Ref_attr(attr::T, i) where {T<:AbstractVector}
    length(attr) >= i || error("Indexing ($i) out of bounds vector $attr")
    Ref(attr, i)
end

function get_Ref_attr(attr, i)
    Ref(attr)
end


"""
    update_mtg_models!(mtg::MultiScaleTreeGraph.Node, i, attr_name::Symbol)

Update the mtg models initialisations by using the ith time-step. The mtg is considered fully
initialized already once, so [`init_mtg_models!`](@ref) must be called before
`update_mtg_models!`.

The values are updated only for node attributes in `to_init`. Those attributes must have
several time-steps, *i.e.* indexable by 1:n time-steps.
"""
function update_mtg_models!(mtg::MultiScaleTreeGraph.Node, i, to_init, attr_name::Symbol)

    MultiScaleTreeGraph.traverse!(mtg) do node
        # If the component has models associated to it
        if haskey(to_init, node.MTG.symbol)
            # Set the initialisation value of the model at the ith value of the node attribute

            # Get the default initialisation values from the previous time-step:
            as_default = NamedTuple(var => Ref(status(node[attr_name], var)[i]) for var in setdiff(keys(status(node[attr_name])), to_init[node.MTG.symbol]))

            # Make a new ModelList with the updated values pointing to the ith value in the attributes
            node[attr_name] = copy(
                node[attr_name],
                TimeStepTable([
                    Status(
                        merge(
                            as_default,
                            NamedTuple(j => get_Ref_i(node, j, i) for j in to_init[node.MTG.symbol])
                        )
                    )
                ])
            )
            # Note that it is mandantory to copy the ModeList as it is immutable
        end
    end

    return nothing
end
