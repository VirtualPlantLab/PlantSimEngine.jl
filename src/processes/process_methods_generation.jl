"""
    @gen_process_methods(process::String, doc::String=""; verbose::Bool=true)

This macro generate the abstract type and standard functions for a process, along with 
their documentation and prints out a little tutorial about how to implement a model.

The abstract process type is then used as a supertype of all models implementations for the 
process, and is named "Abstract<ProcessName>Model", *e.g.* `AbstractGrowthModel` for
a process called growth.

The three following functions are also generated (replace "process" by your own process name):
- `process`: a non mutating function that makes a copy of the object
- `process!`: a mutating function that updates the object status
- `process!_`: the actual workhorse function that does the computation, and is called by the 
two previous functions under the hood. Modelers implement their own method for this function 
for their own model types.

The two first functions have several methods:

- The base method that runs over one time-step and one object.
- The method applying the computation over several objects (*e.g.* all leaves of a plant)
in an Array
- The same method over a Dict(-alike) of objects
- The method that applies the computation over several meteo time steps and
possibly several objects
- A method for calling the process without any meteo (*e.g.* for fitting)
- A method to apply the above over MTG nodes (see details)

The first argument to `@gen_process_methods` is the new process name, 
the second is any additional documentation that should be added 
to the `process` and `process!` functions, and the third determines whether 
the short tutorial should be printed or not.

# Examples

```julia
@gen_process_methods "dummy_process" "This is a dummy process that shall not be used"
```
"""
macro gen_process_methods(f, doc::String=""; verbose=true)

    non_mutating_f = process_field = Symbol(f)
    mutating_f = Symbol(string(f, "!"))
    f_ = Symbol(string(mutating_f, "_")) # The actual function implementing the process

    # We need strings for the docs: 
    f_str = string(f_)
    mutating_f_str = string(mutating_f)
    non_mutating_f_str = string(non_mutating_f)
    process_name = string(process_field)
    process_abstract_type_name = string("Abstract", titlecase(process_name), "Model")
    process_abstract_type = Symbol(process_abstract_type_name)

    expr = quote

        # Default method, when no model is implemented yet, or when the model is not associated to the process we try to simulate
        @doc """
        $($f_str)(
            mod_type::DataType,
            object::ModelList,
            status,
            meteo::M=nothing, 
            constants=PlantMeteo.Constants(), 
            extra=nothing
        ) where {M<:Union{PlantMeteo.AbstractAtmosphere,Nothing}). 

        The base function for the simulation of the `$($process_name)` process. 
        Modelers should implement a method for this function for their own model type, and 
        `PlantSimEngine.jl` will automatically handle everything else.

        # Arguments

        - `mod_type::DataType`: The type of the model to use for the simulation, used for 
        dispatching to the right model implementation.
        - `object::ModelList`: The list of models to simulate.
        - `status`: The status of the simulation, usually from the object, but not always (can be a 
        subset of for e.g. one time-step).
        - `meteo::M`: The meteo data to use for the simulation.
        - `constants=PlantMeteo.Constants()`: The constants to use for the simulation.
        - `extra=nothing`: Extra arguments to pass to the model. This is useful for *e.g.* passing
         the node of an MTG to the model.

        # Notes

        This function is the simulation workhorse, and is called by the `$($non_mutating_f_str)` 
        and `$($mutating_f_str)` functions under the hood. 

        Users should never have to call this function directly.
        """
        function $(esc(f_))(mod_type, models, status, meteo=nothing, constants=nothing, extra=nothing)
            process_models = Dict(process => typeof(getfield(models, process)).name.wrapper for process in keys(models))
            error(
                "No model was found for this combination of processes:",
                "\nProcess simulation: ", $(String(non_mutating_f)),
                "\nModels: ", join(["$(i.first) => $(i.second)" for i in process_models], ", ", " and ")
            )
        end

        # Base method that calls the actual algorithms (NB: or calling it without meteo too):
        function $(esc(mutating_f))(object::ModelList{T,S}, meteo::M=nothing, constants=PlantMeteo.Constants(), extra=nothing) where {T,S<:Status,M<:Union{PlantMeteo.AbstractAtmosphere,Nothing}}
            $(esc(f_))(object.models.$(process_field), object.models, object.status, meteo, constants, extra)
            return nothing
        end

        # Method for a status with several TimeSteps but one meteo only (or no meteo):
        function $(esc(mutating_f))(object::ModelList{T,S}, meteo::M=nothing, constants=PlantMeteo.Constants(), extra=nothing) where {T,S,M<:Union{PlantMeteo.AbstractAtmosphere,Nothing}}

            for i in Tables.rows(status(object))
                $(esc(f_))(object.models.$(process_field), object.models, i, meteo, constants, extra)
            end

            return nothing
        end

        # Process method over several objects (e.g. all leaves of a plant) in an Array
        function $(esc(mutating_f))(object::O, meteo::PlantMeteo.AbstractAtmosphere, constants=PlantMeteo.Constants(), extra=nothing) where {O<:AbstractArray}
            for i in values(object)
                $(mutating_f)(i, meteo, constants, extra)
            end
            return nothing
        end

        # Process method over several objects (e.g. all leaves of a plant) in a kind of Dict.
        function $(esc(mutating_f))(object::O, meteo::PlantMeteo.AbstractAtmosphere, constants=PlantMeteo.Constants(), extra=nothing) where {O<:AbstractDict}
            for (k, v) in object
                $(mutating_f)(v, meteo, constants, extra)
            end
            return nothing
        end

        # Process method over several meteo time steps (called Weather) and possibly several components:
        function $(esc(mutating_f))(
            object::T,
            meteo::Weather,
            constants=PlantMeteo.Constants(),
            extra=nothing
        ) where {T<:Union{AbstractArray,AbstractDict}}

            # Check if the meteo data and the status have the same length (or length 1)
            check_dimensions(object, meteo)

            # Each object:
            for obj in object
                # Computing for each time-step:
                for (i, meteo_i) in enumerate(meteo.data)
                    $(esc(f_))(obj.models.$(process_field), obj.models, obj[i], meteo_i, constants, extra)
                end
            end

        end

        # If we call weather with one component only:
        function $(esc(mutating_f))(object::T, meteo::Weather, constants=PlantMeteo.Constants(), extra=nothing) where {T<:ModelList}

            # Check if the meteo data and the status have the same length (or length 1)
            check_dimensions(object, meteo)

            # Computing for each time-steps:
            for (i, meteo_i) in enumerate(meteo.data)
                $(esc(f_))(object.models.$(process_field), object.models, object.status[i], meteo_i, constants, extra)
            end
        end

        # Compatibility with MTG:
        function $(esc(mutating_f))(
            mtg::MultiScaleTreeGraph.Node,
            models::Dict{String,M},
            meteo::PlantMeteo.AbstractAtmosphere,
            constants=PlantMeteo.Constants()
        ) where {M<:ModelList}
            # Define the attribute name used for the models in the nodes
            attr_name = MultiScaleTreeGraph.cache_name("PlantSimEngine models")

            # initialize the MTG nodes with the corresponding models:
            init_mtg_models!(mtg, models, attr_name=attr_name)

            MultiScaleTreeGraph.transform!(
                mtg,
                (node) -> $(mutating_f)(node[attr_name], meteo, constants, node),
                ignore_nothing=true
            )
        end

        # Compatibility with MTG + Weather, compute all nodes for one time step, then move to the next time step.
        function $(esc(mutating_f))(
            mtg::MultiScaleTreeGraph.Node,
            models::Dict{String,M},
            meteo::Weather,
            constants=PlantMeteo.Constants()
        ) where {M<:ModelList}
            # Define the attribute name used for the models in the nodes
            attr_name = Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models"))

            # Init the status for the meteo step only (with an PlantMeteo.AbstractAtmosphere)
            to_init = init_mtg_models!(mtg, models, 1, attr_name=attr_name)
            #! Here we use only one time-step for the status whatever the number of timesteps
            #! to simulate. Then we use this status for all the meteo steps (we re-initialize
            #! its values at each step). We do this to not replicate much data, but it is not
            #! the best way to do it because we don't use the nice methods from above that
            #! control the simulations for meteo / status timesteps. What we could do instead
            #! is to have a TimeSteps status for several timesteps, and then use pointers to
            #! the values in the node attributes. This we would avoid to replicate the data
            #! and we could use the fancy methods from above.

            # Pre-allocate the node attributes based on the simulated variables and number of steps:
            nsteps = length(meteo)

            MultiScaleTreeGraph.traverse!(
                mtg,
                (x -> pre_allocate_attr!(x, nsteps; attr_name=attr_name)),
            )

            # Computing for each time-steps:
            for (i, meteo_i) in enumerate(meteo.data)
                # Then update the initialisation each time-step.
                update_mtg_models!(mtg, i, to_init, attr_name)

                MultiScaleTreeGraph.transform!(
                    mtg,
                    (node) -> Symbol($(esc(process_field))) in keys(node[attr_name].models) && $(mutating_f)(node[attr_name], meteo_i, constants, node),
                    (node) -> pull_status_one_step!(node, i, attr_name=attr_name),
                    ignore_nothing=true
                )
            end
        end

        # Non-mutating version (make a copy before the call, and return the copy):
        function $(esc(non_mutating_f))(
            object::O,
            meteo::Union{Nothing,PlantMeteo.AbstractAtmosphere,Weather}=nothing,
            constants=PlantMeteo.Constants(),
            extra=nothing
        ) where {O<:Union{ModelList,AbstractArray,AbstractDict}}
            object_tmp = copy(object)
            $(esc(mutating_f))(object_tmp, meteo, constants, extra)
            return object_tmp
        end

        @doc string("""
        $($mutating_f_str)(
            object::ModelList,
            meteo::M=nothing, 
            constants=PlantMeteo.Constants(), 
            extra=nothing
        ) where {M<:Union{PlantMeteo.AbstractAtmosphere,Nothing}). 


        $($non_mutating_f_str)(
            object::ModelList,
            meteo::M=nothing, 
            constants=PlantMeteo.Constants(), 
            extra=nothing
        ) where {M<:Union{PlantMeteo.AbstractAtmosphere,Nothing}). 

        $($mutating_f_str)(
            object::MultiScaleTreeGraph.Node,
            models::Dict{String,M},
            meteo::Weather,
            constants=PlantMeteo.Constants()
        )


        Computes the `$($process_name)` process for one or several components based on the type of 
        the model the object was parameterized with in `object.$($process_name)`, and on one or 
        several meteorology time-steps.

        # Arguments
        - `object::ModelList`: the object to simulate. It can be a `ModelList`, a `Dict` or an `AbstractArray` of,
        or a MultiScaleTreeGraph.Node.
        - `models::Dict{String,M}`: the models to use for the simulation. It is a `Dict` with the node symbols as 
        keys and the associated ModelList as value. It is used only for the MTG version.
        - `meteo::Union{Nothing,PlantMeteo.AbstractAtmosphere,Weather}`: the meteo data to use for the simulation.
        - `constants=PlantMeteo.Constants()`: the constants to use for the simulation.
        - `extra=nothing`: extra data to use for the simulation.

        # Returns 

        The non mutating function returns a simulated copy of the object, and the
        mutating version modifies the object passed as argument, and returns nothing. 
        Users may retrieve the results from the object using the [`status`](@ref) function (see examples).

        # Notes

        The models available for this process can be listed using `subtypes` on the process 
        abstract type:

        ```julia
        subtypes($($process_abstract_type_name))
        ```

        This function calls `$($f_str)` under the hood, but manages the details about time-steps,
        objects and MTG nodes.

        # Examples

        Import the packages: 

        ```julia
        using PlantSimEngine, PlantMeteo
        ```

        Create a model implementation:

        ```julia
        struct DummyModel <: Abstract$(titlecase($process_name))Model end
        ```

        Define the inputs and outputs of the model with default values:

        ```julia
        PlantSimEngine.inputs_(::DummyModel) = (X = -Inf, )
        PlantSimEngine.outputs_(::DummyModel) = (Y = -Inf, )
        ```

        Implement the model:

        ```julia
        function $($f_str)(::DummyModel,object,status,meteo,constants,extra=nothing)
            status.Y = status.X + meteo.T
        end
        ```

        Create a model list with a dummy model, and initalize X to 0.0:

        ```julia
        models = ModelList(
            $($process_name) = DummyModel(),
            status = (X=0.0,),
        )
        ```

        Create a meteo

        ```julia
        meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65)
        ```

        Simulate the process:

        ```julia
        $($mutating_f_str)(models, meteo)
        ```

        Retrieve the results:

        ```julia
        (models[:X],models[:Y])
        ```
        """, $(doc))
        $(mutating_f), $(non_mutating_f)

        # Generate the abstract struct for the process:
        @doc """
        `$($process_name)` process abstract model. 

        All models implemented to simulate the `$($process_name)` process must be a subtype of this type, *e.g.* 
        `struct My$($(titlecase(process_name)))Model <: $($process_abstract_type_name) end`.

        You can list all models implementing this process using `subtypes`:

        # Examples

        ```julia
        subtypes($($process_abstract_type_name))
        ```
        """
        abstract type $(esc(process_abstract_type)) <: AbstractModel end
        # Docs.getdoc(t::$(esc(process_abstract_type))) = "Documentation for MyType with value $(t.value)"
    end

    # Print help when creating a process:
    dummy_type_name = string("My", titlecase(process_name), "Model")
    p = Term.RenderableText(
        Markdown.parse("""\'{underline bold red}$(process_name){/underline bold red}\' process, generated:

        * {#8abeff}$(mutating_f)(){/#8abeff} to compute the process in-place.      

        * {#8abeff}$(non_mutating_f)(){/#8abeff} to compute the process and return a copy.    

        * {#8abeff}$(f_)(){/#8abeff} that is used to call the actual model implementation.    

        * {#8abeff}$process_abstract_type{/#8abeff}, an abstract struct used as a supertype for models implementations.

        !!! tip "What's next?"
            You can now define one or several models implementations for the {underline bold red}$(process_name){/underline bold red} process
            by adding a method to {#8abeff}$(f_){/#8abeff} with your own model type

        Here's an example implementation:

        ```julia
        # Define a new model type:
        struct $(dummy_type_name) <: $process_abstract_type
            # The model parameters here, *e.g.*:
            a::Float64
        end

        # Define the model inputs and outputs by adding methods 
        # to inputs_ and outputs_ from PlantSimEngine:
        PlantSimEngine.inputs_(::$(dummy_type_name)) = (X=-Inf,)
        PlantSimEngine.outputs_(::$dummy_type_name) = (Y=-Inf,)

        # Define the model implementation by adding a method to $(f_):
        function $(f_)(
            ::$dummy_type_name,
            models,
            status,
            meteo,
            constants,
            extra
        )
            # The model implementation is given here, *e.g.*:
            status.Y = model.$(process_name).a * meteo.CO2 + status.X
        end
        ```

        !!! tip "Variables and parameters usage"
            Note that {#8abeff}$(f_){/#8abeff} takes six arguments: the model type (used
            for dispatch), the ModelList, the status, the meteorology, the constants and
            any extra values.
            Then we can use variables from the status as inputs or outputs, model parameters
            from the ModelList (indexing by process, here using "$(process_name)" as the
            process name), and meteorology variables.
        """
        )
    )

    isinteractive() && verbose && print(p)

    return expr
end
