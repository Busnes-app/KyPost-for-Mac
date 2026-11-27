#!/bin/bash
#
# Runs xcodebuild and, on failure, replays the interesting lines as GitHub
# `::error::` annotations.
#
# This exists because job logs require admin rights on the repository. Without
# it a red run reads "Process completed with exit code 65" to everyone else,
# which is how two rounds of CI fixes ended up being guesswork against a
# number. Annotations are visible to anyone who can see the run.

set -uo pipefail

"$(dirname "$0")/build-gopenpgp.sh" || exit $?

LOG=${RUNNER_TEMP:-/tmp}/xcodebuild.log

# GitHub treats a literal newline as the end of a workflow command, so
# multi-line context has to be encoded. awk rather than sed: BSD sed on the
# macOS runner rejects the usual newline-slurping one-liner.
annotate() {
  printf '::error::%s\n' \
    "$(printf '%s' "$1" | awk 'BEGIN{ORS=""} NR>1{print "%0A"} {print}')"
}

STATUS=0
xcodebuild "$@" 2>&1 | tee "$LOG" || STATUS=$?
[ "$STATUS" -eq 0 ] && exit 0

# Compile, link and signing errors first: these explain everything after them.
grep -E '(^|[[:space:]])error:' "$LOG" | sort -u | head -10 \
  | while IFS= read -r line; do annotate "$line"; done

# Then the failing tests, the other reason to be reading this.
grep -E '✘|Testing failed:' "$LOG" | sort -u | head -10 \
  | while IFS= read -r line; do annotate "$line"; done

annotate "xcodebuild exited $STATUS. Last 40 lines:%0A$(tail -40 "$LOG")"
exit "$STATUS"
