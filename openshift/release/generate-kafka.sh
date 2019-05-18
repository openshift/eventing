#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

output_file="openshift/release/knative-eventing-kafka-${release}.yaml"

if [ $release = "ci" ]; then
    image_prefix="image-registry.openshift-image-registry.svc:5000/knative-eventing/knative-eventing-"
    tag=""
else
    image_prefix="quay.io/openshift-knative/knative-eventing-"
    tag=$release
fi

# Apache Kafka channel
resolve_resources contrib/kafka/config/ kafka-resolved.yaml $image_prefix $release
cat kafka-resolved.yaml >> $output_file
rm kafka-resolved.yaml
