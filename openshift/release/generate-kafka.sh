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
# TODO: remove in 0.8.0 - because the deprecated CCP is removed by than
resolve_resources contrib/kafka/config/provisioner/ ccp-kafka-resolved.yaml $image_prefix $release
cat ccp-kafka-resolved.yaml >> $output_file
rm ccp-kafka-resolved.yaml

# Apache Kafka channel CRD
resolve_resources contrib/kafka/config/ crd-kafka-resolved.yaml $image_prefix $release
cat crd-kafka-resolved.yaml >> $output_file
rm crd-kafka-resolved.yaml
