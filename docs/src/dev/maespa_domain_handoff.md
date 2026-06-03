# MAESPA-Style Domain Example Handoff

The example in `examples/maespa_domain_example.jl` is the target API for the
new hard-domain design.

## API Expectations

- `HardDomains(kind=:plant, scale=:Leaf, process=:leaf_eb)` selects models that
  are hard dependencies of the declaring model.
- Hard-domain targets are excluded from normal domain scheduling.
- Parent models retrieve selected targets with
  `dependency_targets(extra, :dependency_name)`.
- Parent models execute selected targets with `run_target!(target)`.
- `run_target!(target; publish=true)` publishes the hard-run model outputs
  to domain streams and `DomainSimulation.outputs`.
- Trial target runs still mutate the target status. Irreversible accumulators
  such as growth/carbon pools should be committed only after the accepted final
  target run, not inside every trial iteration.
- `explain_domain_dependencies(sim)` reports hard-domain dependencies with
  `mode=:hard_domain`.

## Scheduler Expectations

- `AllDomains` keeps stream-reading semantics for normally scheduled producers.
- `HardDomains` keeps hard-dependency semantics for manually run producers.
- Normal plant allocation models are not hard-called by scene models.
- Daily allocation models run through the normal dependency graph after scene
  hard-runs have published leaf outputs.

## Example Verification

- Species A has two leaves.
- Species B has three leaves.
- `LeafEB`, `FvCB`, `Tuzet`, and `SoilWater` are driven through `SceneEB`, not
  through normal scheduling.
- `AllocA` and `AllocB` run normally on a daily clock.
- Leaf temperature, assimilation, transpiration, canopy air state, and soil
  water potential remain finite and change during the run.
- Allocation differs between species because their parameters differ.
