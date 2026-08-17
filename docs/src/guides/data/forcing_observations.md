# Forcing Observed Variables

Supply a constant observed value in object status when it does not vary. For a
time-varying observation, use a small environment-driven source model that
publishes the canonical variable; downstream applications remain unchanged.

Replace a process for an entire template instance through instance overrides,
or use `Override` for one exceptional object. The replacement must implement
the same process and input/output contract.

