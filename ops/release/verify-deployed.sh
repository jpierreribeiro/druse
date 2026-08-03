#!/usr/bin/env bash
# R2-WP08 — prove the deployed bytes are the approved bytes.
#
#   usage: verify-deployed.sh APPROVAL_RECORD DEPLOYED_ARTEFACT [REPORT_PATH]
#
# The verification half of the amended exit criterion. `approve-artefact.sh`
# wrote the record; this reads it, hashes what is actually on the target, and
# compares. Exit 0 only on a match.
#
# THREE FAILURES THIS REFUSES TO CALL A PASS, because each of them is how a
# hash check quietly stops checking anything:
#
#   1. the deployed file is absent — an unreadable target is not a match;
#   2. the approval record carries no `artefact_sha256` — comparing against the
#      empty string succeeds for any file, so a truncated or hand-edited record
#      must be an error rather than a comparison;
#   3. the sizes agree — size is not identity. The measurement that forced this
#      whole amendment produced two binaries of *exactly* 918,640 bytes with
#      different contents, so any shortcut that compares length is wrong here by
#      demonstration and not by principle.
set -uo pipefail

APPROVAL="${1:-}"
DEPLOYED="${2:-}"
REPORT="${3:-/dev/stdout}"

notes=(); problems=()
note() { notes+=("$1"); }
problem() { problems+=("$1"); }

emit() {
  {
    echo "verify_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for line in "${notes[@]}"; do echo "$line"; done
    if (( ${#problems[@]} == 0 )); then
      echo "deployed_identity=match"
      echo "verify=pass"
    else
      echo "deployed_identity=mismatch"
      echo "verify=fail"
      for line in "${problems[@]}"; do echo "problem=$line"; done
    fi
  } >"$REPORT"
  (( ${#problems[@]} == 0 ))
}

if [[ -z "$APPROVAL" || -z "$DEPLOYED" ]]; then
  problem "usage: verify-deployed.sh APPROVAL_RECORD DEPLOYED_ARTEFACT [REPORT_PATH]"
  emit; exit 1
fi
if [[ ! -f "$APPROVAL" ]]; then
  problem "approval_unreadable: no such record: $APPROVAL"
  emit; exit 1
fi

approved="$(sed -n 's/^artefact_sha256=//p' "$APPROVAL" | head -n 1)"
approved_bytes="$(sed -n 's/^artefact_bytes=//p' "$APPROVAL" | head -n 1)"
approved_commit="$(sed -n 's/^commit=//p' "$APPROVAL" | head -n 1)"

# Failure 2. An empty expectation must never reach the comparison.
if [[ ! "$approved" =~ ^[0-9a-f]{64}$ ]]; then
  problem "approval_unreadable: $APPROVAL carries no well-formed artefact_sha256; a comparison against an empty expectation passes for every file"
  emit; exit 1
fi
note "approval_record=$APPROVAL"
note "approved_sha256=$approved"
note "approved_commit=${approved_commit:-unknown}"

# Failure 1.
if [[ ! -f "$DEPLOYED" ]]; then
  problem "deployed_missing: no such file on the target: $DEPLOYED"
  emit; exit 1
fi

found="$(sha256sum "$DEPLOYED" | awk '{print $1}')"
found_bytes="$(stat -c %s "$DEPLOYED")"
note "deployed_path=$(readlink -f "$DEPLOYED")"
note "deployed_sha256=$found"
note "deployed_bytes=$found_bytes"

if [[ "$found" != "$approved" ]]; then
  # Failure 3, stated in the report rather than left for a reader to infer: when
  # the sizes match and the hashes do not, the natural next thought is "close
  # enough" or "the compiler again". Neither is a deployment claim.
  if [[ -n "$approved_bytes" && "$approved_bytes" == "$found_bytes" ]]; then
    problem "the deployed file is $found_bytes bytes, exactly as approved, and hashes differently: identical size is not identity, and this is the case the rebuild measurement produced"
  else
    problem "the deployed file hashes to $found, and $approved was approved"
  fi
fi

emit
