#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/e2e-common.sh"

set -x

env

scale_up_workers || exit 1

failed=0

(( !failed )) && install_strimzi || failed=1

(( !failed )) && install_serverless || failed=1

(( !failed )) && install_knative_eventing || failed=1

(( !failed )) && install_zipkin || failed=1

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

(( failed )) && exit 1

success
