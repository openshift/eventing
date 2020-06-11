#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1
suffix=$2

if [ $suffix = "ci" ]; then
    output_file="openshift/release/knative-eventing-${suffix}.yaml"
    image_prefix="registry.svc.ci.openshift.org/openshift/knative-${release}:knative-eventing-"
    tag=""
else
    suffix=${release}
    output_file="openshift/release/knative-eventing-${suffix}.yaml"
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
output_file="openshift/release/knative-eventing-channelbroker-${suffix}.yaml"
resolve_resources config/brokers/channel-broker/ channelbroker-resolved.yaml $image_prefix $tag
cat channelbroker-resolved.yaml >> $output_file
rm channelbroker-resolved.yaml

# the MT Broker:
output_file="openshift/release/knative-eventing-mtbroker-${suffix}.yaml"
resolve_resources config/brokers/mt-channel-broker/ mtbroker-resolved.yaml $image_prefix $tag
cat mtbroker-resolved.yaml >> $output_file
rm mtbroker-resolved.yaml
