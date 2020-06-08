#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

output_file="openshift/release/knative-eventing-${release}.yaml"

if [ $release = "ci" ]; then
    image_prefix="image-registry.openshift-image-registry.svc:5000/knative-eventing/knative-eventing-"
    tag=""
else
    image_prefix="quay.io/openshift-knative/knative-eventing-"
    tag=$release
fi

# the core parts
resolve_resources config/ $output_file $image_prefix $tag

# InMemoryChannel CRD
resolve_resources config/channels/in-memory-channel/ crd-channel-resolved.yaml $image_prefix $tag
cat crd-channel-resolved.yaml >> $output_file
rm crd-channel-resolved.yaml

# the Channel Broker:
output_file="openshift/release/knative-eventing-channelbroker-${release}.yaml"
resolve_resources config/brokers/channel-broker/ channelbroker-resolved.yaml $image_prefix $tag
cat channelbroker-resolved.yaml >> $output_file
rm channelbroker-resolved.yaml

# the MT Broker:
output_file="openshift/release/knative-eventing-mtbroker-${release}.yaml"
resolve_resources config/brokers/mt-channel-broker/ mtbroker-resolved.yaml $image_prefix $tag
cat mtbroker-resolved.yaml >> $output_file
rm mtbroker-resolved.yaml
