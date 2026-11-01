#!/bin/sh
# JuliaC bundles JLL artifacts under share/julia; configure their lookup before
# libjulia runs package initializers. The native image itself remains unchanged.
set -eu
bundle_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
export JULIA_DEPOT_PATH="$bundle_root/share/julia"
exec "$bundle_root/bin/pse_program" "$@"
