#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/e2e-common.sh"

set -x

env

failed=0

(( !failed )) && run_e2e_tests "$TEST" || failed=1

(( failed )) && dump_cluster_state

(( failed )) && exit 1

success
