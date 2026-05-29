#!/usr/bin/env bash
exec "$(dirname -- "${BASH_SOURCE[0]}")/lib/ps1-delegate.sh" check-iis-listening "$@"
