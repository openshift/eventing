#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

output_file="openshift/release/knative-eventing-${release}.yaml"
image_prefix="quay.io/openshift-knative/knative-eventing-"

if [ $release = "ci" ]; then
    tag="latest"
else
    tag=$release
fi

# the core parts
resolve_resources config/ $output_file $image_prefix $tag

# the MT broker:
resolve_resources config/brokers/mt-channel-broker/deployments mtbroker-deployments-resolved.yaml $image_prefix $tag
cat mtbroker-deployments-resolved.yaml >> $output_file
rm mtbroker-deployments-resolved.yaml

resolve_resources config/brokers/mt-channel-broker/roles mtbroker-roles-resolved.yaml $image_prefix $tag
cat mtbroker-roles-resolved.yaml >> $output_file
rm mtbroker-roles-resolved.yaml

# InMemoryChannel CRD
resolve_resources config/channels/in-memory-channel/ crd-channel-resolved.yaml $image_prefix $tag
cat crd-channel-resolved.yaml >> $output_file
rm crd-channel-resolved.yaml