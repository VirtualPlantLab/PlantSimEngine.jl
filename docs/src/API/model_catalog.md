# Loaded model catalog

This catalog is generated from the Julia modules loaded by the documentation
build. It is not a manually maintained registry: downstream packages appear
after they are loaded, and a type without a zero-argument constructor remains
visible as an incomplete, best-effort description.

```@example loaded-model-catalog
using DataFrames
using PlantSimEngine

rows = NamedTuple[]
descriptions = Authoring.ModelDescription[]
for process_type in Authoring.available_processes()
    model_types = Authoring.available_models(process_type)
    if isempty(model_types)
        push!(rows, (
            process=missing,
            process_type=string(process_type),
            model="<no loaded concrete model>",
            package=missing,
            provenance=:unavailable,
            complete=false,
            parameter_provenance=:unavailable,
            diagnostics="no concrete model loaded",
        ))
        continue
    end

    for model_type in model_types
        description = Authoring.describe_model(model_type)
        push!(descriptions, description)
        parameter_field = description.field_provenance.parameters
        push!(rows, (
            process=description.process,
            process_type=something(description.process_type, ""),
            model=description.model_type,
            package=something(description.package, ""),
            provenance=description.provenance,
            complete=description.complete,
            parameter_provenance=parameter_field isa NamedTuple ?
                                 parameter_field.values : parameter_field,
            diagnostics=join(
                string.(getfield.(description.diagnostics, :code)),
                ", ",
            ),
        ))
    end
end

catalog = DataFrame(rows)
sort!(catalog, [:process_type, :model])
catalog
```

`provenance=:best_effort` means the row was requested from a type. When
`complete=false`, inspect `diagnostics` and pass the concrete instance used by
the scenario to `Authoring.describe_model(instance)` before making decisions
about its parameters or interface. The nested `parameter_provenance` column
also distinguishes exact values from declared metadata and unavailable data.

## Port and scientific-contract catalog

The long table below is generated from each `ModelDescription.ports` entry.
Missing values remain missing: an incomplete type description produces an
explicit `:unavailable` row rather than guessed ports or contracts.

```@example loaded-model-catalog
port_rows = NamedTuple[]
for description in descriptions
    port_field = description.field_provenance.ports
    declaration_provenance = port_field isa NamedTuple ?
                             port_field.declarations : port_field
    contract_provenance = port_field isa NamedTuple ?
                          port_field.contracts : port_field

    if isempty(description.ports)
        availability = description.complete ? :none : :unavailable
        push!(port_rows, (
            process=description.process,
            model=description.model_type,
            complete=description.complete,
            role=availability,
            port=availability,
            declaration=availability,
            expected_type=string(availability),
            unit=missing,
            basis=missing,
            temporal=missing,
            aggregation=missing,
            extent=missing,
            declaration_provenance=declaration_provenance,
            contract_provenance=contract_provenance,
        ))
        continue
    end

    for port in description.ports
        contract = port.variable_contract
        push!(port_rows, (
            process=description.process,
            model=description.model_type,
            complete=description.complete,
            role=port.role,
            port=port.name,
            declaration=port.declaration,
            expected_type=port.expected_type,
            unit=isnothing(contract) ? missing : contract.unit,
            basis=isnothing(contract) ? missing : contract.basis,
            temporal=isnothing(contract) ? missing : contract.temporal,
            aggregation=isnothing(contract) ? missing : contract.aggregation,
            extent=isnothing(contract) ? missing : contract.extent,
            declaration_provenance=declaration_provenance,
            contract_provenance=contract_provenance,
        ))
    end
end

port_catalog = DataFrame(port_rows)
sort!(port_catalog, [:process, :model, :role, :port])
port_catalog
```

The same pattern can generate a package-specific process page after loading
that package. Filter the table by `package`, then enrich the human-facing page
with assumptions, equations, references, domain of validity, and scientific
validation evidence; Authoring deliberately does not infer those claims.
