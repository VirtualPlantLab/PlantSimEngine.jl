# Defining the process:
PlantSimEngine.@process "maintenance_respiration" verbose = false

"""
    RmQ10FixedN(Q10, Rm_base, T_ref, P_alive, nitrogen_content)

Maintenance respiration based on a Q10 computation with fixed nitrogen values 
and proportion of living cells in the organs.

# Arguments

- `Q10`: Q10 factor (values should usually range between: 1.5 - 2.5, with 2.1 being the most common value)
- `Rm_base`: Base maintenance respiration (gC gDM⁻¹ d⁻¹). Should be around 0.06.
- `T_ref`: Reference temperature at which Q10 was measured (usually around 25.0°C)
- `P_alive`: proportion of living cells in the organ
- `nitrogen_content`: nitrogen content of the organ (gN gC⁻¹)
"""
struct ToyMaintenanceRespirationModel{T} <: AbstractMaintenance_RespirationModel
    Q10::T
    Rm_base::T
    T_ref::T
    P_alive::T
    nitrogen_content::T
end

PlantSimEngine.inputs_(::ToyMaintenanceRespirationModel) = (biomass=0.0,)
PlantSimEngine.outputs_(::ToyMaintenanceRespirationModel) = (Rm=-Inf,)

function PlantSimEngine.run!(m::ToyMaintenanceRespirationModel, models, status, meteo, constants, extra=nothing)
    status.Rm =
        status.biomass * m.P_alive * m.nitrogen_content * m.Rm_base *
        m.Q10^((meteo.T - m.T_ref) / 10.0)
end

"""
    PlantRm()

Total plant maintenance respiration based on the sum of `Rm_organs`, the maintenance respiration of the organs.

# Intputs

- `Rm_organs`: a vector of maintenance respiration from all organs in the plant in gC d⁻¹

# Outputs

- `Rm`: the total plant maintenance respiration in gC d⁻¹
"""
struct ToyPlantRmModel <: AbstractMaintenance_RespirationModel end

PlantSimEngine.inputs_(::ToyPlantRmModel) = (Rm_organs=[-Inf],)
PlantSimEngine.outputs_(::ToyPlantRmModel) = (Rm=-Inf,)

function PlantSimEngine.run!(::ToyPlantRmModel, models, status, meteo, constants, extra=nothing)
    status.Rm = sum(status.Rm_organs)
end