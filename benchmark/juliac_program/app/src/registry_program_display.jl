# Included inside RegistryPrograms. Diagnostic signatures must remain bounded:
# recursively printing the full graph in every context/schema parameter can
# spend minutes formatting a single verifier error. These methods affect only
# display; scientific payloads and all safe-verifier checks are unchanged.
Base.show(io::IO,::Type{<:RegistryState})=print(io,"RegistryState{…}")
Base.show(io::IO,::Type{<:RegistrySeed})=print(io,"RegistrySeed{…}")
Base.show(io::IO,::Type{<:RegistryTarget})=print(io,"RegistryTarget{…}")
Base.show(io::IO,::Type{<:RegistryGroup})=print(io,"RegistryGroup{…}")
Base.show(io::IO,::Type{<:RegistryProgram})=print(io,"RegistryProgram{…}")
Base.show(io::IO,::Type{<:RegistryContext})=print(io,"RegistryContext{…}")
Base.show(io::IO,::Type{<:RegistryCallTarget})=print(io,"RegistryCallTarget{…}")
Base.show(io::IO,::Type{<:RegistryCallTargets})=print(io,"RegistryCallTargets{…}")
Base.show(io::IO,::Type{<:TypedSeedCopies.CopySchema})=print(io,"TypedSeedCopySchema{…}")
Base.show(io::IO,::Type{<:TypedSeedCopies.CopyPlan})=print(io,"TypedSeedCopyPlan{…}")
