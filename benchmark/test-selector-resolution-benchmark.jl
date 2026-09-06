using PlantSimEngine

"""
Build an XPalm-shaped chain where every phytomer owns one reproductive organ.
The newest phytomer has a two-object subtree, while the oldest phytomer spans
the complete chain, so the same selector benchmarks both the bounded
scope-first path and its registry-index fallback.
"""
function setup_subtree_selector_resolution_benchmark(nphytomers::Int=2_048)
    nphytomers > 0 || throw(ArgumentError("`nphytomers` must be positive."))
    objects = Object[
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
    ]
    previous_phytomer_id = :plant
    for index in 1:nphytomers
        phytomer_id = Symbol(:phytomer_, index)
        male_id = Symbol(:male_, index)
        push!(
            objects,
            Object(
                phytomer_id;
                scale=:Phytomer,
                parent=previous_phytomer_id,
            ),
        )
        push!(
            objects,
            Object(male_id; scale=:Male, parent=phytomer_id),
        )
        previous_phytomer_id = phytomer_id
    end

    model = CompositeModel(objects...)
    selector = Many(scale=:Male, within=Subtree())
    return (
        model=model,
        selector=selector,
        matcher=PlantSimEngine._compile_selector_matcher(model, selector),
        tip_context=ObjectId(Symbol(:phytomer_, nphytomers)),
        root_context=ObjectId(:phytomer_1),
    )
end

Base.@noinline function benchmark_subtree_selector_resolution(data, context)
    return PlantSimEngine._resolve_object_ids(
        data.model,
        data.selector,
        data.matcher;
        context=context,
    )
end
