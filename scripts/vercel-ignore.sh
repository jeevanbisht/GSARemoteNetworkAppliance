#!/usr/bin/env bash
#
# Vercel "Ignored Build Step" helper for this monorepo.
#
# Both the control-plane and the portal live in one repo but deploy as two
# separate Vercel projects. By default Vercel rebuilds *every* project on *every*
# push. Use this script as each project's Ignored Build Step so a project only
# rebuilds when its own files (or shared deps) change.
#
# Vercel dashboard -> Project -> Settings -> Git -> Ignored Build Step:
#   control-plane project:  bash scripts/vercel-ignore.sh apps/control-plane
#   portal project:         bash scripts/vercel-ignore.sh apps/portal
#
# Exit code contract (Vercel):
#   exit 0  -> changes detected, PROCEED with build
#   exit 1  -> no relevant changes, SKIP the build
#
# Note: Vercel runs this from the *repo root* with VERCEL_GIT_PREVIOUS_SHA set on
# normal pushes. The first deploy (no previous SHA) always builds.
set -euo pipefail

watch_path="${1:-}"
if [[ -z "${watch_path}" ]]; then
  echo "usage: vercel-ignore.sh <path> [extra_path...]" >&2
  # Be safe: build rather than silently skip on misconfiguration.
  exit 0
fi

# Always include shared workspace packages so a change there rebuilds everyone.
paths=("$@" "packages")

prev="${VERCEL_GIT_PREVIOUS_SHA:-}"
if [[ -z "${prev}" ]]; then
  echo "No previous SHA (first deploy / unknown) -> building."
  exit 0
fi

if git diff --quiet "${prev}" HEAD -- "${paths[@]}"; then
  echo "No changes under: ${paths[*]} -> skipping build."
  exit 1
fi

echo "Changes detected under: ${paths[*]} -> building."
exit 0
