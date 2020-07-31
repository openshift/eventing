#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/../test/e2e-common.sh"
source "$(dirname "$0")/release/resolve.sh"

readonly SERVING_NAMESPACE=knative-serving
readonly SERVICEMESH_NAMESPACE=knative-serving-ingress
readonly EVENTING_NAMESPACE=knative-eventing
readonly OLM_NAMESPACE=openshift-marketplace

# Determine if we're running locally or in CI.
if [ -n "$OPENSHIFT_BUILD_NAMESPACE" ]; then
  # A golang template to point the tests to the right image coordinates.
  # {{.Name}} is the name of the image, for example 'logevents'.
  # IMAGE_FORMAT variable provided by ci-operator.
  readonly TEST_IMAGE_TEMPLATE="${IMAGE_FORMAT//\$\{component\}/knative-eventing-test-{{.Name}}}"
elif [ -n "$DOCKER_REPO_OVERRIDE" ]; then
  readonly TEST_IMAGE_TEMPLATE="${DOCKER_REPO_OVERRIDE}/{{.Name}}"
elif [ -n "$BRANCH" ]; then
  readonly TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/${BRANCH}:knative-eventing-test-{{.Name}}"
elif [ -n "$TEMPLATE" ]; then
  readonly TEST_IMAGE_TEMPLATE="$TEMPLATE"
else
  readonly TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/knative-nightly:knative-eventing-test-{{.Name}}"
fi

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset
  machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} "${machineset}" -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} "${machineset}" 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for _ in {1..150}; do  # timeout after 15 minutes
    local available
    available=$(oc get machineset -n "$1" "$2" -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "Error: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_strimzi(){
  strimzi_version=`curl https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null`
  header_text "Strimzi install"
  kubectl create namespace kafka
  curl -L "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${strimzi_version}/strimzi-cluster-operator-${strimzi_version}.yaml" \
  | sed 's/namespace: .*/namespace: kafka/' \
  | kubectl -n kafka apply -f -

  header_text "Applying Strimzi Cluster file"
  kubectl -n kafka apply -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent-single.yaml"

  header_text "Waiting for Strimzi to become ready"
  sleep 5; while echo && kubectl get pods -n kafka | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
}

function install_serverless(){
  header "Installing Serverless Operator"
  git clone --branch release-1.6 https://github.com/openshift-knative/serverless-operator.git /tmp/serverless-operator
  # unset OPENSHIFT_BUILD_NAMESPACE as its used in serverless-operator's CI environment as a switch
  # to use CI built images, we want pre-built images of k-s-o and k-o-i
  unset OPENSHIFT_BUILD_NAMESPACE
  /tmp/serverless-operator/hack/install.sh || return 1
  header "Serverless Operator installed successfully"
}

function create_knative_namespace(){
  local COMPONENT="knative-$1"

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  create_knative_namespace eventing

  cat openshift/release/knative-eventing-ci.yaml > ci
  cat openshift/release/knative-eventing-channelbroker-ci.yaml >> ci
  cat openshift/release/knative-eventing-mtbroker-ci.yaml >> ci

  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-controller}|g"                               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-ping|${IMAGE_FORMAT//\$\{component\}/knative-eventing-ping}|g"                                           ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtping|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtping}|g"                                       ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-apiserver-receive-adapter|${IMAGE_FORMAT//\$\{component\}/knative-eventing-apiserver-receive-adapter}|g" ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-webhook|${IMAGE_FORMAT//\$\{component\}/knative-eventing-webhook}|g"                                     ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-channel-controller}|g"               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-dispatcher|${IMAGE_FORMAT//\$\{component\}/knative-eventing-channel-dispatcher}|g"               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-broker|${IMAGE_FORMAT//\$\{component\}/knative-eventing-channel-broker}|g"                       ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-broker-ingress|${IMAGE_FORMAT//\$\{component\}/knative-eventing-broker-ingress}|g"                       ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-broker-filter|${IMAGE_FORMAT//\$\{component\}/knative-eventing-broker-filter}|g"                         ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-ingress|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtbroker-ingress}|g"                   ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-filter|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtbroker-filter}|g"                     ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtchannel-broker|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtchannel-broker}|g"                   ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-sugar-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-sugar-controller}|g"                   ci

  oc apply -f ci
  rm ci

  # Wait for 5 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $EVENTING_NAMESPACE --no-headers | wc -l) -lt 5 ]]' || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  # Assert that there are no images used that are not CI images (which should all be using the $INTERNAL_REGISTRY)
  # (except for the knative-eventing-operator)
  #oc get pod -n knative-eventing -o yaml | grep image: | grep -v knative-eventing-operator | grep -v ${INTERNAL_REGISTRY} && return 1 || true
}

function install_zipkin(){


  header "Setting Zipkin"
  oc create namespace zipkin

oc apply -n zipkin -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: zipkin
spec:
  type: NodePort
  ports:
  - name: http
    port: 9411
  selector:
    app: zipkin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zipkin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zipkin
  template:
    metadata:
      labels:
        app: zipkin
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: zipkin
        image: docker.io/openzipkin/zipkin:latest
        ports:
        - containerPort: 9411
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        resources:
          limits:
            memory: 1000Mi
          requests:
            memory: 256Mi
---
EOF

  sleep 5; while echo && kubectl get pods -n zipkin | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

  header "Configuring Zipkin for eventing"

  oc apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-tracing
  namespace: knative-eventing
data:
  enable: "true"
  zipkin-endpoint: "http://zipkin.zipkin.svc.cluster.local:9411/api/v2/spans"
  sample-rate: "1.0"
  debug: "true"
EOF

}

function run_e2e_tests(){
  header "Running tests with Multi Tenant Channel Based Broker"

  local test_name=$1
  local failed=0
  local channels=messaging.knative.dev/v1beta1:Channel,messaging.knative.dev/v1beta1:InMemoryChannel
  local common_opts="-channels=$channels --kubeconfig $KUBECONFIG --imagetemplate $TEST_IMAGE_TEMPLATE $options"

  k get ns ${TEST_EVENTING_NAMESPACE} 2>/dev/null || TEST_EVENTING_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${TEST_EVENTING_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} > tmp.tracing.config.yaml
  oc replace -f tmp.tracing.config.yaml
  rm tmp.tracing.config.yaml

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  if [ -n "$test_name" ]; then # Running a single test.
    go_test_e2e -timeout=15m -parallel=1 ./test/e2e \
      -run "^(${test_name})$" \
      -brokerclass=MTChannelBasedBroker \
      "$common_opts" || failed=$?
  else
    go_test_e2e -timeout=90m -parallel=12 ./test/e2e \
      -brokerclass=MTChannelBasedBroker \
      "$common_opts" || failed=$?
  fi

  return $failed
}
