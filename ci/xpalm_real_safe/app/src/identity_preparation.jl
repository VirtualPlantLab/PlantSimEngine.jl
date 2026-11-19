# PRIVATE OPTIONAL authored-application preparation, not a change to open PSE.
# Call after the real xpalm_scene and BEFORE run!(steps=0), only if Root accepts
# the certified MTG-only Int identity domain for this frozen XPalm application.
function _prepare_xpalm_integer_id_domain(model)
    adapter = model.source_adapter
    adapter isa PSE.MTGObjectAdapter || error("XPalm identity preparation requires its real MTG adapter.")
    adapter.id === XPalm.MultiScaleTreeGraph.node_id ||
        error("XPalm identity preparation requires the unmodified MTG node_id accessor.")
    isnothing(model.binding_cache) && isnothing(model.environment_binding_cache) ||
        error("Prepare XPalm identities before any runtime bindings.")
    I = PSE.ObjectId{Int}
    for object in PSE.model_objects(model)
        object.id isa I || error("XPalm initial objects must have Int MTG identities.")
        node = PSE.source_node(model, object.id)
        object.id.value === XPalm.MultiScaleTreeGraph.node_id(node) ||
            error("XPalm object identity differs from its MTG node.")
    end
    previous = model.registry
    objects = PSE._closed_object_family_store(previous.objects)
    keytype(objects) === I || error("XPalm did not prepare the certified Int identity domain.")
    registry = PSE.ObjectRegistry(objects, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    source_adapter = PSE._closed_mtg_object_adapter(adapter, I)
    fields = map(fieldnames(typeof(model))) do name
        name === :registry && return registry
        name === :source_adapter && return source_adapter
        return getfield(model, name)
    end
    prepared = PSE.CompositeModel(fields...)
    PSE._model_owned_scenario_preparation(prepared, model.scenario_plan_cache)
    return prepared
end
