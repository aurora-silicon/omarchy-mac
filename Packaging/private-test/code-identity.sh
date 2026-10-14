#!/bin/bash
# Compatibility names for the shared exact code identity implementation.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/code-identity.sh"
private_code_hash() { code_hash "$@"; }
private_code_requirement() { code_requirement "$@"; }

# Both flags are authenticated bundle resources. Ambiguous/ordinary bundles are
# not accepted by this private installer path.
private_bundle_profile() {
  local app=$1 plain limine file
  plain=$(/usr/bin/plutil -extract OmarchyPrivatePlainTest raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  limine=$(/usr/bin/plutil -extract OmarchyPrivateLimineTest raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  if [[ $plain == "true" && $limine != "true" ]]; then
    echo plain
  elif [[ $limine == "true" && $plain != "true" ]]; then
    for file in catalog.json catalog.json.sig; do
      [[ -f $app/Contents/Resources/Release/$file && ! -L $app/Contents/Resources/Release/$file ]] || return 1
    done
    echo limine
  else
    echo 'An unambiguous private plain or Limine profile is required.' >&2
    return 1
  fi
}
