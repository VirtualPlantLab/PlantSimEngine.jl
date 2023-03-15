# status on an mtg node returns the status of the models.
function status(node::T, key) where {T<:MultiScaleTreeGraph.NodeMTG}
    status(node[:models], key)
end

function status(node::T) where {T<:MultiScaleTreeGraph.NodeMTG}
    status(node[:models])
end