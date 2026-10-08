# Shared helpers for the build scripts; source it, do not run it.

# Print the whole build log only when the build fails; a bare `| tail -1` hides the error.
build_or_die() {
  local out
  if ! out=$("$@" 2>&1); then echo "$out"; echo "build failed" >&2; exit 1; fi
  echo "$out" | tail -1
}
