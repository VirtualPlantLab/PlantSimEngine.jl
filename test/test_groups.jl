# Keep dependent files together: each group runs in order in one process.
const TEST_GROUPS = (
    "Unified model/object API" => (
        "test-unified-model-object-api.jl",
    ),
    "Registered object identity" => (
        "test-model-object-id.jl",
        "test-object-families.jl",
    ),
    "Concrete runtime object identities" => (
        "test-model-concrete-object-identities.jl",
    ),
    "Persistent typed execution cohorts" => (
        "test-execution-cohorts.jl",
        "test-execution-cohort-refresh.jl",
        "test-model-canonical-cohorts.jl",
        "test-model-persistent-empty-groups.jl",
        "test-model-slot-group-refresh.jl",
    ),
    "Prepared execution schemas" => (
        "test-model-closed-cohort-schemas.jl",
        "test-model-cohort-store-identities.jl",
        "test-model-status-view-cache-admission.jl",
        "test-model-call-cohort-retirement.jl",
        "test-model-closed-group-refresh.jl",
        "test-model-closed-group-layout-preflight.jl",
        "test-model-prepared-call-schemas.jl",
        "test-model-prepared-call-vector-api.jl",
        "test-model-prepared-growth-schemas.jl",
        "test-model-target-status-view-admission.jl",
        "test-model-prepared-missing-future-schema.jl",
        "test-model-finite-call-extension-intents.jl",
    ),
    "Organ creation allocations" => (
        "test-organ-creation-allocation.jl",
    ),
    "Lifecycle snapshot allocations" => (
        "test-lifecycle-snapshot-allocations.jl",
    ),
    "Structural delta binding intersection" => (
        "test-structural-delta-intersection.jl",
    ),
    "Organ status assembly" => (
        "test-organ-status-assembly.jl",
        "test-status-construction.jl",
    ),
    "CompositeModel display" => (
        "test-model-display.jl",
    ),
    "Composite Model/Object API stabilization" => (
        "test-model-api-stabilization.jl",
    ),
    "Reusable scenario plans" => (
        "test-model-prepared-scenario.jl",
        "test-model-scenario-authoring.jl",
        "test-model-authored-port-inventory.jl",
        "test-model-authored-input-graph.jl",
        "test-model-prepared-authoring-owner.jl",
        "test-model-public-refresh-owners.jl",
        "test-model-authored-call-plans.jl",
        "test-model-spec-normalization.jl",
        "test-model-runtime-snapshot-isolation.jl",
        "test-model-refreshed-schedule.jl",
        "test-model-authored-spec-matching.jl",
        "test-compilation-metadata.jl",
        "test-model-input-recipes.jl",
        "test-model-binding-index-identities.jl",
        "test-model-input-binding-storage.jl",
        "test-model-output-retention-owners.jl",
        "test-input-default-values.jl",
        "test-application-membership-slots.jl",
        "test-registered-status-dispatch.jl",
        "test-owned-metadata-tables.jl",
        "test-resolved-input-materialization.jl",
        "test-input-source-matching.jl",
    ),
    "Isolated model diagnostics" => (
        "test-model-diagnostic-isolation.jl",
        "test-model-diagnostic-authoring-recovery.jl",
    ),
    "Public native compilation API" => (
        "test-native-compilation.jl",
    ),
    "Typed temporal initial values" => (
        "test-model-temporal-initial-typing.jl",
    ),
    "Concrete selector construction" => (
        "test-selector-construction-inference.jl",
    ),
    "Selector candidate scope fast path" => (
        "test-selector-candidate-empty-scope.jl",
        "test-selector-query-scope-root.jl",
        "test-selector-query-scope-append.jl",
        "test-selector-ancestor-index.jl",
    ),
    "Lifecycle without target additions" => (
        "test-model-lifecycle-empty-targets.jl",
    ),
    "Public model authoring API" => (
        "test-authoring-api.jl",
    ),
    "Process authoring tutorial" => (
        "test-process-generation.jl",
    ),
    "Packaged PlantSimEngine agent skill" => (
        "test-agent-skill.jl",
    ),
    "Readable CompositeModel source" => (
        "test-model-source-compilation.jl",
    ),
    "Composite model hard calls" => (
        "test-model-hard-calls.jl",
    ),
    "Accepted call evaluations" => (
        "test-model-call-evaluations.jl",
        "test-model-call-execution-identity.jl",
        "test-call-evaluation-parent-generation.jl",
    ),
    "Prepared environment inputs" => (
        "test-prepared-environment-inputs.jl",
    ),
    "Transient manual-call context reuse" => (
        "test-model-call-context-cache.jl",
        "test-model-call-context-cloning.jl",
    ),
    "Lightweight manual-call target views" => (
        "test-model-lightweight-call-targets.jl",
    ),
    "Collected hard-call target types" => (
        "test-model-collected-call-targets.jl",
    ),
    "Reusable scoped hard-call targets" => (
        "test-model-reusable-call-targets.jl",
    ),
    "Materialized manual-call dispatch" => (
        "test-model-materialized-call-dispatch.jl",
    ),
    "Singular manual-call snapshot cache" => (
        "test-model-single-call-snapshot-cache.jl",
    ),
    "Singular manual-call target access" => (
        "test-model-only-call-targets.jl",
    ),
    "Transient singular manual-call views" => (
        "test-model-transient-single-call-views.jl",
    ),
    "Individual manual-call environments" => (
        "test-model-individual-call-environments.jl",
    ),
    "Individual environments in generated source" => (
        "test-model-individual-source-environment.jl",
    ),
    "Newborn retained manual calls" => (
        "test-model-newborn-retention.jl",
    ),
    "Scheduled newborn initializers" => (
        "test-model-initializers.jl",
        "test-model-newborn-execution-owner.jl",
        "test-model-newborn-context-initializer.jl",
        "test-model-newborn-context-nested.jl",
        "test-model-runtime-call-names.jl",
    ),
    "Composite model numerical parity" => (
        "test-model-numerical-parity.jl",
    ),
    "Composite model status initialization" => (
        "test-model-status-initialization.jl",
    ),
    "Initial status preparation" => (
        "test-initial-status-preparation.jl",
    ),
    "Manual producers in Many inputs" => (
        "test-manual-many-input-filter.jl",
    ),
    "Composite model status type conversion" => (
        "test-model-status-type-conversion.jl",
    ),
    "Composite model status type conversion runtime" => (
        "test-model-status-type-runtime.jl",
    ),
    "Composite model status type conversion lifecycle" => (
        "test-model-status-type-lifecycle.jl",
    ),
    "Composite model status type conversion temporal policies" => (
        "test-model-status-type-temporal.jl",
    ),
    "Composite model status type conversion with particles" => (
        "test-model-status-type-particles.jl",
    ),
    "Composite model status type conversion templates" => (
        "test-model-status-type-templates.jl",
    ),
    "Composite model status type conversion performance" => (
        "test-model-status-type-performance.jl",
    ),
    "Composite model output boundaries" => (
        "test-model-output-boundaries.jl",
        "test-model-empty-output-requests.jl",
    ),
    "Composite model output datetimes" => (
        "test-model-output-datetime.jl",
    ),
    "Composite model time validation" => (
        "test-model-time-validation.jl",
    ),
    "Composite model runtime matrix" => (
        "test-model-runtime-matrix.jl",
    ),
    "Composite model environment sampling" => (
        "test-model-environment-sampling.jl",
        "test-model-execution-batch-times.jl",
        "test-model-environment-binding-identity.jl",
        "test-model-environment-index-identities.jl",
        "test-model-global-environment-sample-schema.jl",
    ),
    "Composite model temporal reducers" => (
        "test-model-temporal-reducers.jl",
    ),
    "PreviousTimeStep application-local status views" => (
        "test-model-previous-timestep-views.jl",
    ),
    "Composite model binding inference" => (
        "test-model-binding-inference.jl",
    ),
    "Compile-local output name metadata" => (
        "test-model-input-plan-output-metadata.jl",
    ),
    "Adaptive subtree selectors" => (
        "test-model-adaptive-selectors.jl",
    ),
    "Identity-aware Many inputs" => (
        "test-model-bound-many.jl",
    ),
    "Distributed output declarations" => (
        "test-model-output-destination-declarations.jl",
        "test-model-distributed-route-ownership.jl",
    ),
    "Distributed output runtime" => (
        "test-model-distributed-output-runtime.jl",
        "test-model-runtime-stream-extensions.jl",
    ),
    "Distributed output assignment API" => (
        "test-model-output-targets-api.jl",
    ),
    "Composite model multirate integration" => (
        "test-model-multirate-integration.jl",
    ),
    "Composite model configuration errors" => (
        "test-model-configuration-errors.jl",
    ),
    "Model discovery" => (
        "test-model-discovery.jl",
    ),
    "Model graph viewer" => (
        "test-model-graph-view.jl",
    ),
    "Model graph editor extension" => (
        "test-model-graph-editor-extension.jl",
    ),
    "Model contract" => (
        "test-model-contract.jl",
    ),
    "ModelSpec Updates" => (
        "test-updates.jl",
    ),
    "Environment traits" => (
        "test-environment-traits.jl",
    ),
    "Environment backends" => (
        "test-environment-backends.jl",
    ),
    "MAESPA-style model example" => (
        "test-maespa-model-example.jl",
    ),
    "Two-plant allocation comparison" => (
        "test-two-plant-allocation.jl",
    ),
    "Status" => (
        "test-Status.jl",
    ),
    "TimeStepTable" => (
        "test-TimeStepTable.jl",
    ),
    "Statistics" => (
        "test-statistics.jl",
    ),
    "Fitting" => (
        "test-fitting.jl",
    ),
    "Toy models" => (
        "test-toy_models.jl",
    ),
    "Readable-source call evaluation acceptance" => (
        "test-model-source-call-evaluations.jl",
    ),
    "Temporal inputs inside call evaluations" => (
        "test-model-call-evaluation-temporal-inputs.jl",
    ),
)
