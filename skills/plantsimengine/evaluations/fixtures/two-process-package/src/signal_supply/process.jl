PlantSimEngine.@process "fixture_signal_supply" verbose=false

const FIXTURE_SIGNAL_CONTRACT = VariableContract(
    unit=:arbitrary_signal_unit,
    basis=:object,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)
