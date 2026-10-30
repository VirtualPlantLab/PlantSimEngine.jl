function _resolved_context_with_calls(
    original::PSE.RunContext{CS,A,CT,BI,OT,TS,OR,C,E}, table,
) where {CS,A,CT,BI,OT,TS,OR,C,E}
    # Preserve the source executor's erased/local fields. Rebuilding through
    # the broad outer constructor would reintroduce concrete scene-wide types
    # in CS/A/TS when composing with local_context=true. The new call table is
    # intentionally concrete; its own remaining type dependencies are reported.
    return PSE.RunContext{CS,A,typeof(table),BI,OT,TS,OR,C,E}(
        original.compiled, original.environment_bindings,
        original.application, original.object_id, table, original.bound_inputs,
        original.output_targets, original.temporal_streams,
        original.output_retention, original.time, original.constants,
        original.publication_allowed, original.environment)
end
