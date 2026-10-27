#!/bin/sh
# Offline checks only. This script does not install Shelf or move menu bar icons.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/reliability-evidence
EVIDENCE=.build/reliability-evidence
rm -f "$EVIDENCE/passed.txt"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$EVIDENCE/started.txt"
shasum -a 256 Package.swift Sources/ShelfCore/*.swift Sources/shelf/*.swift Sources/Shelf*Test/*.swift > "$EVIDENCE/sources.sha256"
git diff --check > "$EVIDENCE/diff-check.log" 2>&1
swift build > "$EVIDENCE/build.log" 2>&1 || {
    cat "$EVIDENCE/build.log"
    exit 1
}
FAILED=0
for SUITE in ShelfSelfTest ShelfDisplayTest ShelfRecoveryTest ShelfPersistenceTest; do
    swift run --skip-build "$SUITE" > "$EVIDENCE/$SUITE.log" 2>&1 || FAILED=1
    cat "$EVIDENCE/$SUITE.log"
done
if [ "$FAILED" -ne 0 ]; then
    echo "One or more suites failed. All available results are saved in $EVIDENCE."
    exit 1
fi
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$EVIDENCE/passed.txt"
echo "Offline checks passed. Evidence: $EVIDENCE"
echo "The installed app is unchanged. Live tests are a separate gate."
