module PersistentXPSourceAudit

using SHA, XPalm
const Native=Main.NativePBDriver
const Shared=Main.SharedCallProgram
const Tight=Main.TightCallProgram

export verify_xp_source_audit, XP_SOURCE_AUDIT

# A small source audit using the existing PRIVATE-context capability contracts.
# Ports, selectors, calls, cadence and ownership still come from PSE declarations.
# These original kernels use no context or lifecycle API. Growth/pruning, Many hard calls,
# distributed/temporal/private and spatial boundaries keep the ordinary executor.
# Hashes pin the inspected downstream implementation; this is opt-in evidence,
# not inference that a context-free signature proves effect freedom.
const XP_SOURCE_AUDIT = (
    (model=:DailyDegreeDaysSinceInit, source="meteo/thermal_time.jl", sha256="01010362e59c70349b3a1b846c463ac0fe02aa420817c9684f3eb7aa22feb164"),
    (model=:DailyPlantAgeModel, source="plant/plant_age/palm_age_increment.jl", sha256="7b132b6f6386854227b9bab4603824b9ead21c444dac4ae74c94781f931f193a"),
    (model=:PotentialAreaModel, source="plant/phytomer/leaves/potential_area.jl", sha256="2ab57a07b116993fb0f1c73fe41234ac85e1558157bdd49e6245f75fd95bc432"),
    (model=:LeafBiomass, source="plant/phytomer/leaves/biomass.jl", sha256="e451e294b5e8b428f91c918eef888e91e418fb57b1f79db75ded312ff377beb8"),
    (model=:InternodeBiomass, source="plant/phytomer/internode/biomass.jl", sha256="af840d49bdfb81fd0184109459f2baabdc863d7f0dbbfbdb6da28dc239b25f4f"),
    (model=:RootGrowthFTSW, source="plant/roots/root_growth.jl", sha256="8512000f14706fdbed74cea7717cf59ce7cbb99f2d2541f86ec28293229b9411"),
)

function verify_xp_source_audit()
    root=pkgdir(XPalm)
    for row in XP_SOURCE_AUDIT
        path=joinpath(root,"src",row.source)
        bytes2hex(sha256(read(path)))==row.sha256 || error("XP source changed after audit: $(row.source)")
    end
    return (verified=true, path=root, models=XP_SOURCE_AUDIT,
        scope=:six_original_context_unused_numeric_kernels_only)
end

# Admit only the ordinary numeric parameter types inspected in the pilot.
# Unknown numeric/model families receive existing full-protocol defaults.
for T in (XPalm.DailyDegreeDaysSinceInit, XPalm.DailyPlantAgeModel{Int},
    XPalm.PotentialAreaModel{Float64}, XPalm.LeafBiomass{Float64},
    XPalm.InternodeBiomass{Float64}, XPalm.RootGrowthFTSW{Float64})
    @eval Native.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{$T})=Tight._TIGHT_CAPABILITY
end

end # module
