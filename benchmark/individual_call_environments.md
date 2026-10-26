# Individual provider-aware hard calls — 26 October 2026

This change gives the public individual `run_call!(target; ...)` the same
`environment=trial_state` backend override already available to named bulk
calls. It reuses the existing private execution path; it does not add a model,
cache, macro, MAESPA-specific branch or alternative scheduler.

The provider samples each target through its own handle, and descendants use
their own bindings against the trial backend. `sampled_environment=value`
remains immediate-only. Supplying both keywords fails before input
materialization or sampling. Neither override changes the captured default
environment, time or inherited publication permission. Normal runtime calls
keep their existing context lease and exception release.

The source-export helper accepts the same keyword and early conflict check.
The generated backend retains its pre-existing lease/publication-membership
differences; the tests below do not establish universal generated-backend
reentrancy or structural-lifecycle equivalence.

## Focused qualification

Two complete new files pass 560 assertions: 456 runtime/provider/lifecycle
checks and 104 generated-source checks. They cover Float32/Float64, remapping
and spatial handles, immediate versus descendant sampling, trial publication
masking, A/B/default backend reuse, retained timestamps, dual-override failure
before mutation, same-target reentry, exception recovery, and newborn calls
when both binding schemas already exist. Generated functions are invoked
across the correct world-age boundary in the test harness.

An initial fixture exposed an unrelated existing failure: an initially empty
spatial owner can infer an environment-binding dictionary too narrowly to add
the first differently bound leaf. The immutable parent `0f35a47f` reproduces
the same conversion failure in `_refresh_environment_bindings_for_objects`,
before the new individual API is called. This change does not repair or claim
support for that case. The permanent newborn fixture explicitly includes an
existing seed leaf and verifies it remains unexecuted.

The first smoke attempt is preserved as a failed diagnostic, not counted as a
passing gate. Its other error was a generated-function world-age error in the
test harness. The corrected focused run and separate parent reproduction both
finish normally. Default-route regression adds sixteen complete runtime files
and 2,413 passing assertions (including environments, newborn retention,
temporal/distributed bindings, publication, context leases, lightweight views
and source export). Together these are eighteen targeted files / 2,973 fresh
passing assertions, not the full package suite. Downstream scientific
experiments are separate.

## Default-route micro-observations

Same driver and benchmark fixture, immutable parent `0f35a47f` versus candidate,
three warmed batches of 10,000 invocations per route, Julia 1.13.1, two compute
threads/one GC thread, `--compile=yes -O1 --compiled-modules=existing`.
All nine routes allocate zero measured bytes in both versions.

| Public-call route | Parent median ns | Candidate median ns |
| --- | ---: | ---: |
| Singular | 28.75 | 28.70 |
| Repeated eight times | 237.32 | 231.77 |
| Nested | 74.35 | 72.74 |
| Many, eight targets | 195.85 | 214.30 |
| Heterogeneous | 78.86 | 82.22 |
| Already sampled | 18.17 | 18.07 |
| Transient backend | 29.00 | 28.87 |
| Nested transient backend | 58.79 | 59.03 |
| Published | 29.27 | 29.20 |

These are sequential desktop observations, not confidence intervals or a
universal speedup claim. The default private runner is unchanged; introducing
an explicit backend on an individual call is a capability, not by itself an
optimization. No independent cold-compilation, peak-runtime-memory or object
creation improvement is established here.

## Provenance

Local controlled children are started by Kaimon, bounded to 30 minutes and
sampled 8 GiB RSS, with a separate keep-awake helper and a 2-second monitor.
The corrected focused child/helper exit 0/signal 0, its monitor finishes in
42.114977 s with sampled peak 1234.05 MiB, all four final logs are read, source
guards remain unchanged and no monitor observation fails. The parent
reproduction finishes in 18.052484 s, peak 1192.73 MiB, with the same clean
termination/guard checks. Allocation volumes are not simultaneous RAM.
The default-runtime child/helper also exit 0/signal 0, all four logs are read,
and source guards and monitor checks remain clean: fixed monitor duration
447.672564 s, sampled peak 1953.69 MiB.

Runtime source SHA256:
`4a2aac88739df4b08f0dc0c424e7b2c6f7ebbdeade455df996f8c9d3c38c1bae`.
Source-export helper SHA256:
`0ea4da36ba090bca4289412fc1c9b6aa4584c111862f068d01e164df929af522`.

Local raw route tables are under MAESPA's ignored
`legacy_fortran/validation/2026-10-25-pse-contexts/`, labels
`individual-parent-0f35-v1` and `individual-api-current-v1`. The parent export
is immutable and uses the same dependency manifest. No dependency adoption,
upstream merge or release is included.
