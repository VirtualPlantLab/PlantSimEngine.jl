"""Literal leaf-output writes and finite respiration error propagation only."""

REPAIRED = (
    "src/processes/leaf_exchange/compact_calls.jl",
    "src/processes/civil_day_respiration_accumulator.jl",
)


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("Expected exactly one source occurrence: " + old[:100])
    return source.replace(old, new, 1)


def repair(relative, source):
    if relative == REPAIRED[0]:
        for prefix in ("non_tuzet_accepted_logical_leaf_", "accepted_logical_leaf_"):
            old = (
                "    for (name, value) in pairs(_coupled_crown_values(solution))\n"
                '        getproperty(result, Symbol("' + prefix + '", name))[unit] = value\n'
                "    end"
            )
            new = (
                "    _store_coupled_leaf_values!(result, unit, _coupled_crown_values(solution),\n"
                "        Val(:" + prefix + "))"
            )
            source = replace_once(source, old, new)
        return source + """

# Preserve the NamedTuple's field/write order and live destination vectors.
@inline @generated function _store_coupled_leaf_values!(result, unit,
    values::NamedTuple{names}, ::Val{prefix}) where {names,prefix}
    assignments = [:(getproperty(result, $(QuoteNode(Symbol(prefix,name))))[unit] =
        getproperty(values, $(QuoteNode(name)))) for name in names]
    return Expr(:block, assignments..., :(return nothing))
end
"""
    if relative == REPAIRED[1]:
        return replace_once(
            source,
            "@noinline function _throw_civil_day_respiration_numeric(\n",
            "@inline Base.@constprop :aggressive function _throw_civil_day_respiration_numeric(\n",
        )
    raise ValueError("Not an owned leaf-output typing path: " + relative)
