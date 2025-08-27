#!/usr/bin/env bash

# bash "strict" mode
# https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425
set -euxo pipefail

# THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

export DOCC_HTML_DIR=/Users/joeheck/src/swift-project/swift-docc-render/dist

/Users/joeheck/src/swift-project/swift-docc/.build/debug/docc convert \
    /Users/joeheck/src/swift-metrics/Sources/CoreMetrics/Docs.docc \
    --emit-lmdb-index \
    --fallback-display-name CoreMetrics \
    --fallback-bundle-identifier CoreMetrics \
    --additional-symbol-graph-dir /Users/joeheck/src/swift-metrics/.build/plugins/Swift-DocC/outputs/.build/symbol-graphs/unified-symbol-graphs/CoreMetrics-3 \
    --output-path /Users/joeheck/src/swift-metrics/.build/plugins/Swift-DocC/outputs/intermediates/CoreMetrics.doccarchive
