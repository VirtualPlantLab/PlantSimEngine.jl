# Understanding Model Cadence

`TimeStep(Dates.Period)` sets application cadence. Without it, an application
uses `timespec(model)` when non-default and otherwise the environment base
step. `timestep_hint` validates a scientifically acceptable range; it does not
silently change cadence.

Temporal input policies have different physical meanings: `HoldLast` samples
the latest state, `Aggregate` reduces observations, and `Integrate` multiplies
rates by sample durations. `PreviousTimeStep` deliberately breaks a same-step
cycle. Windows are rolling fixed-duration windows. Civil-day or
previous-complete-calendar-period alignment is not a supported public feature.

