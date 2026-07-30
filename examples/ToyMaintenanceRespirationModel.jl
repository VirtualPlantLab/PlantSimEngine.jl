# Defining the process:
PlantSimEngine.@process "maintenance_respiration" verbose = false

"""
    RmQ10FixedN(Q10, Rm_base, T_ref, P_alive, nitrogen_content)

Maintenance respiration based on a Q10 computation with fixed nitrogen values 
and proportion of living cells in the organs.

# Arguments

- `Q10`: Q10 factor (values should usually range between: 1.5 - 2.5, with 2.1 being the most common value)
- `Rm_base`: Base maintenance respiration (gC gDM⁻¹ time-step⁻¹). Should be around 0.06.
- `T_ref`: Reference temperature at which Q10 was measured (usually around 25.0°C)
- `P_alive`: proportion of living cells in the organ
- `nitrogen_content`: nitrogen content of the organ (gN gC⁻¹)


# Inputs

- `carbon_biomass`: the carbon biomass of the organ in gC


"""
struct ToyMaintenanceRespirationModel{T} <: AbstractMaintenance_RespirationModel
    Q10::T
    Rm_base::T
    T_ref::T
    P_alive::T
    nitrogen_content::T
end

function ToyMaintenanceRespirationModel(Q10, Rm_base, T_ref, P_alive, nitrogen_content)
    parameters = promote(
        float(Q10),
        float(Rm_base),
        float(T_ref),
        float(P_alive),
        float(nitrogen_content),
    )
    return ToyMaintenanceRespirationModel{typeof(first(parameters))}(parameters...)
end

PlantSimEngine.inputs_(::ToyMaintenanceRespirationModel) = (carbon_biomass=Required(Real),)
PlantSimEngine.outputs_(m::ToyMaintenanceRespirationModel) = (Rm=oftype(m.Rm_base, -Inf),)
PlantSimEngine.environment_inputs_(m::ToyMaintenanceRespirationModel) = (T=zero(m.T_ref),)

function PlantSimEngine.run!(m::ToyMaintenanceRespirationModel, status, environment, constants, context=nothing)
    status.Rm =
        status.carbon_biomass * m.P_alive * m.nitrogen_content * m.Rm_base *
        m.Q10^((environment.T - m.T_ref) / 10.0)
end

"""
    ToyPlantRmModel()

Total plant maintenance respiration based on the sum of `Rm_organs`, the maintenance respiration of the organs.

# Intputs

- `Rm_organs`: a vector of maintenance respiration from all organs in the plant in gC time-step⁻¹

# Outputs

- `Rm`: the total plant maintenance respiration in gC time-step⁻¹
"""
struct ToyPlantRmModel <: AbstractMaintenance_RespirationModel end

PlantSimEngine.inputs_(::ToyPlantRmModel) = (Rm_organs=Required(AbstractVector{<:Real}),)
PlantSimEngine.outputs_(::ToyPlantRmModel) = (Rm=-Inf,)

function PlantSimEngine.run!(::ToyPlantRmModel, status, environment, constants, context=nothing)
    status.Rm = sum(status.Rm_organs)
end
