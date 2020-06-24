#!/usr/bin/env bash

export EVENTING_NAMESPACE=knative-eventing
export OLM_NAMESPACE=openshift-marketplace

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

function deploy_knative_operator(){
  local COMPONENT="knative-$1"
  local API_GROUP=$1
  local KIND=$2

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
  if oc get crd operatorgroups.operators.coreos.com >/dev/null 2>&1; then
    cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${COMPONENT}
	  namespace: ${COMPONENT}
	EOF
  fi
  cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${COMPONENT}-subscription
	  generateName: ${COMPONENT}-
	  namespace: ${COMPONENT}
	spec:
	  source: ${COMPONENT}-operator
	  sourceNamespace: $OLM_NAMESPACE
	  name: ${COMPONENT}-operator
	  channel: alpha
	EOF

  # # Wait until the server knows about the Install CRD before creating
  # # an instance of it below
  timeout_non_zero 60 '[[ $(oc get crd knative${API_GROUP}s.${API_GROUP}.knative.dev -o jsonpath="{.status.acceptedNames.kind}" | grep -c $KIND) -eq 0 ]]' || return 1
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  create_knative_namespace eventing

  # oc apply -n $OLM_NAMESPACE -f knative-eventing.catalogsource-ci.yaml
  oc apply -n $OLM_NAMESPACE -f openshift/olm/knative-eventing.catalogsource.yaml
  timeout_non_zero 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c knative-eventing) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  oc get pod -n $OLM_NAMESPACE -o yaml

  # Deploy Knative Operators Eventing
  deploy_knative_operator eventing KnativeEventing

  # Wait for 5 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $EVENTING_NAMESPACE --no-headers | wc -l) -lt 5 ]]' || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  # Assert that there are no images used that are not CI images (which should all be using the $INTERNAL_REGISTRY)
  # (except for the knative-eventing-operator)
  #oc get pod -n knative-eventing -o yaml | grep image: | grep -v knative-eventing-operator | grep -v ${INTERNAL_REGISTRY} && return 1 || true
}

function run_e2e_tests(){
  local test_name="${1:-}"
  local failed=0
  local channels=messaging.knative.dev/v1alpha1:InMemoryChannel,messaging.knative.dev/v1alpha1:Channel,messaging.knative.dev/v1beta1:InMemoryChannel
  local common_opts="-channels=$channels --kubeconfig $KUBECONFIG --imagetemplate $TEST_IMAGE_TEMPLATE"

  header "Running tests with Single Tenant Channel Based Broker"
  oc patch cm config-br-defaults -n $EVENTING_NAMESPACE -p '{"data":{"default-br-config":"clusterDefault:\n  brokerClass: ChannelBasedBroker\n  apiVersion: v1\n  kind: ConfigMap\n  name: config-br-default-channel\n  namespace: '$EVENTING_NAMESPACE'\n"}}' --type=merge ||  return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  if [ -n "$test_name" ]; then # Running a single test.
    go_test_e2e -timeout=15m -parallel=1 ./test/e2e \
      -run "^(${test_name})$" \
      -brokerclass=ChannelBasedBroker \
      "$common_opts" || failed=$?
  else
    go_test_e2e -timeout=90m -parallel=12 ./test/e2e \
      -brokerclass=ChannelBasedBroker \
      "$common_opts" || failed=$?
  fi

  header "Running tests with Multi Tenant Channel Based Broker"
  oc patch cm config-br-defaults -n $EVENTING_NAMESPACE -p '{"data":{"default-br-config":"clusterDefault:\n  brokerClass: MTChannelBasedBroker\n  apiVersion: v1\n  kind: ConfigMap\n  name: config-br-default-channel\n  namespace: '$EVENTING_NAMESPACE'\n"}}' --type=merge ||  return 3
  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 4

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
