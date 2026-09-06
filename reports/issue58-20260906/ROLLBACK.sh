#!/usr/bin/env bash
set -euo pipefail

target="${1:?target file is required}"
baseline="${2:?baseline file is required}"
cp -- "$baseline" "$target"
sha256sum -- "$target"
