"""Value-preserving literal-call inference transforms for the MAESPA copy.

The central recipe owns source copying/inventories. These transforms preserve
the original computations, validation, argument order and payload ownership.
They close literal projections and finite optional calls, add compiler
annotations, and rename one accidentally captured local variable.
"""
import re

REPAIRED = (
    "src/coupling/canopy_environment.jl",
    "src/processes/radiation/radiation_transmission.jl",
    "src/processes/soil_water_balance.jl",
    "src/processes/radiation/crown_radiation.jl",
    "src/processes/soil_shortwave_radiation.jl",
    "src/processes/non_tuzet_leaf_process_calls.jl",
    "src/processes/soil_hydraulics.jl",
    "src/processes/soil_capillarity.jl",
    "src/processes/crown_leaf_respiration_accounting.jl",
    "src/processes/crown_leaf_exchange_aggregation.jl",
)


def replace_exact(source, old, new, count=1):
    if source.count(old) != count:
        raise ValueError(f"Expected {count} occurrences: {old!r}")
    return source.replace(old, new)


def _constant_names(source, name):
    match = re.search(r"const " + re.escape(name) + r" = \((.*?)\n\)", source, re.S)
    if not match:
        raise ValueError("Missing closed field-name tuple: " + name)
    body = match.group(1)
    names = re.findall(r":([A-Za-z_][A-Za-z_0-9]*)", body)
    if re.sub(r":[A-Za-z_][A-Za-z_0-9]*|,|\s", "", body) or not names:
        raise ValueError("Unexpected closed field-name tuple: " + name)
    return names


def _optional_barrier(name, arguments, optionals, forwarded, *, keywords=(), wrapper=None):
    """Close only Nothing tags; each leaf calls the unchanged original kernel.

    `forwarded` retains the original positional argument order. `keywords`
    retains the original keyword order. No numeric expression is moved here.
    """
    def branch(index, values, indent):
        if index == len(optionals):
            positional = ", ".join(values.get(argument, argument) for argument in forwarded)
            named = ", ".join(key + "=" + values.get(argument, argument)
                              for key, argument in keywords)
            return indent + "return " + name + "(" + positional + (
                "; " + named if named else "") + ")\n"
        argument = optionals[index]
        return (indent + "if " + argument + " === nothing\n" +
                branch(index + 1, dict(values, **{argument: "nothing"}), indent + "    ") +
                indent + "else\n" +
                branch(index + 1, values, indent + "    ") + indent + "end\n")

    wrapper = "_closed" + name if wrapper is None else wrapper
    return ("\n# Finite Nothing-tag dispatch only; every leaf invokes the original kernel.\n"
            "function " + wrapper + "(" + ", ".join(arguments) + ")\n" +
            branch(0, {}, "    ") + "end\n")


def _hydraulic_keyword_calls(source):
    # Keep expression evaluation in the same order as the original keyword
    # calls; the helper only sees their already evaluated values.
    specifications = (
        ("potential", "_soil_water_potential_result",
         ("pore_fraction", "b_parameter", "air_entry_water_potential_mpa", "alpha_mpa_inverse",
          "saturated_water_content", "residual_water_content", "shape_parameter_n")),
        ("conductivity", "_soil_hydraulic_conductivity_result",
         ("saturated_hydraulic_conductivity_m_s", "pore_fraction", "b_parameter",
          "saturated_water_content", "residual_water_content", "shape_parameter_n")),
    )
    helpers = []
    for assignment, name, names in specifications:
        expression = re.compile(r"    " + assignment + " = " + re.escape(name) + r"\(\n.*?\n    \)", re.S)
        matches = list(expression.finditer(source))
        if len(matches) != 1:
            raise ValueError("Unexpected hydraulic call: " + name)
        old = matches[0].group()
        new = old.replace(name + "(", "_closed" + name + "(", 1)
        new = replace_exact(new, "        model.method;\n", "        model.method,\n")
        for argument in names:
            new = replace_exact(new, "        " + argument + "=", "        ")
        source = source[:matches[0].start()] + new + source[matches[0].end():]
        optionals = tuple(argument for argument in names if argument not in (
            "pore_fraction", "saturated_hydraulic_conductivity_m_s"))
        # The call's positional order is water, method, then names. Keep the
        # helper's formal arguments in that same order rather than regrouping.
        helper = _optional_barrier(name, ("water", "method") + names, optionals, ("water", "method"),
            keywords=tuple((argument, argument) for argument in names))
        helpers.append(helper)
    return source + "".join(helpers)


def repair(relative, source):
    if relative == REPAIRED[0]:
        source = replace_exact(source,
            "function _sample_canopy_air_trial_metadata(\n",
            "@inline Base.@constprop :aggressive function _sample_canopy_air_trial_metadata(\n")
        source = replace_exact(source,
            "@inline function _sample_canopy_atmosphere(\n",
            "@inline Base.@constprop :aggressive function _sample_canopy_atmosphere(\n")
        source = replace_exact(source,
            "@noinline function _missing_committed_canopy_atmosphere(variable::Symbol)\n",
            "@noinline Base.@constprop :aggressive function _missing_committed_canopy_atmosphere(variable::Symbol)\n")
        source = replace_exact(source,
            "function PlantSimEngine.EnvironmentAPI.sample(\n",
            "@inline Base.@constprop :aggressive function PlantSimEngine.EnvironmentAPI.sample(\n",
            count=3)
        return replace_exact(source,
            "function PlantSimEngine.EnvironmentAPI.commit_environment!(\n",
            "@inline Base.@constprop :aggressive function PlantSimEngine.EnvironmentAPI.commit_environment!(\n")
    if relative == REPAIRED[1]:
        start = source.index("    function uniform_state(crown_index)\n")
        end = source.index("\n    modes = map(eachindex(neighbourhood.tree_ids))", start)
        body = source[start:end]
        if body.count("        values = common_values(crown_index)\n") != 1:
            raise ValueError("Unexpected uniform_state local binding")
        # The outer function also assigns `values`. Reusing its name inside
        # this nested function captures Core.Box; a distinct local is identical
        # here because no caller observes that incidental outer assignment.
        modified, count = re.subn(r"\bvalues\b", "uniform_values", body)
        if count != 11:
            raise ValueError(f"Unexpected uniform_state binding references: {count}")
        source = source[:start] + modified + source[end:]
        for name in ("_aligned_radiation_inputs", "_selected_crowns", "_validate_selected_angle_grids"):
            source = replace_exact(source, "function " + name + "(",
                "@inline Base.@constprop :aggressive function " + name + "(")
        return source
    if relative == REPAIRED[2]:
        source = replace_exact(source,
            "function _load_layer_flux!(\n",
            "@inline Base.@constprop :aggressive function _load_layer_flux!(\n")
        source = replace_exact(source,
            "    ordered_ids = PlantSimEngine.ObjectId[ids[i] for i in positions]\n",
            "    ordered_ids = [ids[i] for i in positions]\n")
        names = _constant_names(source, "_SOIL_WATER_BALANCE_LAYER_OUTPUTS")
        old = """    names = _SOIL_WATER_BALANCE_LAYER_OUTPUTS
    columns = map(names) do name
        source = getproperty(targets.columns, name)
        [source[position] for position in positions]
    end
    return NamedTuple{names}(columns)"""
        # Each original column is read once, then indexed in positions order;
        # the returned vectors remain independent snapshots.
        lines = ["    return ("]
        for name in names:
            lines.extend(("        " + name + "=let source = getproperty(targets.columns, :" + name + ")",
                          "            [source[position] for position in positions]",
                          "        end,"))
        lines.append("    )")
        source = replace_exact(source, old, "\n".join(lines))
        old = """    drainage = soil_gravitational_drainage(
        drain.hydraulics, work.water_content_buffer, work.ice_fraction_buffer;
        drainage_limit=drain.drainage_limit, plateau_drainage=drain.plateau_drainage,
        timestep_seconds=seconds, water_table_layer=drain.water_table_layer,
        capillary_gain_m=capillary.upward_interface_flux_m,
        bottom_water_content=drain.bottom_water_content)"""
        new = """    drainage = _closed_soil_gravitational_drainage(
        drain.hydraulics, work.water_content_buffer, work.ice_fraction_buffer,
        drain.drainage_limit, drain.plateau_drainage,
        seconds, drain.water_table_layer,
        capillary.upward_interface_flux_m,
        drain.bottom_water_content)"""
        source = replace_exact(source, old, new)
        arguments = ("model", "water", "ice", "drainage_limit", "plateau_drainage", "seconds",
                     "water_table_layer", "capillary_gain_m", "bottom_water_content")
        return source + _optional_barrier("soil_gravitational_drainage", arguments,
            ("water_table_layer", "bottom_water_content"), ("model", "water", "ice"),
            keywords=(("drainage_limit", "drainage_limit"), ("plateau_drainage", "plateau_drainage"),
                      ("timestep_seconds", "seconds"), ("water_table_layer", "water_table_layer"),
                      ("capillary_gain_m", "capillary_gain_m"), ("bottom_water_content", "bottom_water_content")),
            wrapper="_closed_soil_gravitational_drainage")
    if relative == REPAIRED[3]:
        return replace_exact(source,
            "    reference = DiffuseCanopyState(Tuple(workspace.reference_canopy)...)\n",
            "    reference = DiffuseCanopyState(workspace.reference_canopy[1], workspace.reference_canopy[2],\n"
            "        workspace.reference_canopy[3], workspace.reference_canopy[4],\n"
            "        workspace.reference_canopy[5], workspace.reference_canopy[6])\n")
    if relative == REPAIRED[4]:
        old = """    weights = Int[]
    for weight in target_weights
        weight isa Integer && !(weight isa Bool) ||
            _throw_soil_shortwave_value(:target_weights, weight, :integer)
        weight > 0 ||
            _throw_soil_shortwave_value(:target_weights, weight, :positive)
        weight <= typemax(Int) || throw(
            ArgumentError("target_weights values must be representable as Int"),
        )
        push!(weights, Int(weight))
    end"""
        new = old.replace("    weights = Int[]\n    for weight in target_weights\n",
                          "    weights = map(target_weights) do weight\n").replace(
                              "        push!(weights, Int(weight))\n", "        Int(weight)\n")
        return replace_exact(source, old, new)
    if relative == REPAIRED[5]:
        old = """    forcing = NamedTuple{_NON_TUZET_CROWN_FLOAT_SCALAR_INPUTS}(map(
        name -> convert(T, getproperty(name in _MAESPA_CANOPY_ATMOSPHERE_AIR_FIELDS ?
            environment : status, name)), _NON_TUZET_CROWN_FLOAT_SCALAR_INPUTS))"""
        source = replace_exact(source, old,
            "    forcing = _closed_leaf_exchange_scalar_forcing(status, environment, T)")
        return source + """
# Literal projections preserve the original tuple order and source selection.
@generated function _closed_leaf_exchange_scalar_forcing(status, environment, ::Type{T}) where {T}
    names = _NON_TUZET_CROWN_FLOAT_SCALAR_INPUTS
    fields = [:(convert(T, getproperty($(name in _MAESPA_CANOPY_ATMOSPHERE_AIR_FIELDS ? :environment : :status),
        $(QuoteNode(name))))) for name in names]
    return Expr(:call, NamedTuple{names}, Expr(:tuple, fields...))
end
"""
    if relative == REPAIRED[6]:
        return _hydraulic_keyword_calls(source)
    if relative == REPAIRED[7]:
        source = replace_exact(source, " = _soil_capillary_potential(\n",
            " = _closed_soil_capillary_potential(\n", count=3)
        source = replace_exact(source, " = _soil_capillary_conductivity(\n",
            " = _closed_soil_capillary_conductivity(\n")
        names = ("water", "method", "pore", "b", "air_entry", "alpha", "saturated", "residual", "shape")
        source += _optional_barrier("_soil_capillary_potential", names,
            ("b", "air_entry", "alpha", "saturated", "residual", "shape"), names)
        names = ("water", "method", "saturated_conductivity", "pore", "b", "saturated", "residual", "shape")
        return source + _optional_barrier("_soil_capillary_conductivity", names,
            ("b", "saturated", "residual", "shape"), names)
    if relative == REPAIRED[8]:
        return replace_exact(source,
            "@noinline function _throw_crown_leaf_respiration_accounting(\n",
            "@noinline Base.@constprop :aggressive function _throw_crown_leaf_respiration_accounting(\n")
    if relative == REPAIRED[9]:
        start = source.index("        names = (:logical_leaf_area_fraction, :logical_leaf_area_density,")
        end = source.index("\n        throw(DimensionMismatch(\"Crown aggregation expects", start)
        old = source[start:end]
        names = re.findall(r":([A-Za-z_][A-Za-z_0-9]*)", old.split("        sizes = ", 1)[0])
        if len(names) != 14:
            raise ValueError("Unexpected crown length diagnostics schema")
        # Identical name=value fragments in the original order, including its
        # comma-space delimiter; no generic status lookup on the error path.
        fragments = ['"' + name + '=$(length(getproperty(status, :' + name + ')))"' for name in names]
        new = "        sizes = join((\n" + "".join("            " + item + ",\n" for item in fragments) + '        ), ", ")'
        return replace_exact(source, old, new)
    raise ValueError("Not an owned runtime-typing source: " + relative)
