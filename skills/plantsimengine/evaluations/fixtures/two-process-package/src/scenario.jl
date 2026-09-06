function fixture_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        ConstantSignal(T(2)),
        LinearResponse(T(3));
        timestep=Day(1),
    )
end
