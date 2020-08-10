#!/usr/bin/env bash

readonly SERVING_NAMESPACE=knative-serving
readonly SERVING_INGRESS_NAMESPACE=knative-serving-ingress
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

# Waits until the given hostname resolves via DNS
# Parameters: $1 - hostname
function wait_until_hostname_resolves() {
  echo -n "Waiting until hostname $1 resolves via DNS"
  for _ in {1..150}; do  # timeout after 15 minutes
    local output
    output=$(host -t a "$1" | grep 'has address')
    if [[ -n "${output}" ]]; then
      echo -e "\n${output}"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo -e "\n\nERROR: timeout waiting for hostname $1 to resolve via DNS"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
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
  header "Installing Knative Serving"

  oc new-project $SERVING_NAMESPACE

  CATALOG_SOURCE="openshift/olm/knative-serving.catalogsource.yaml"

  # release-next branch keeps updating the latest manifest in knative-serving-ci.yaml for serving resources.
  # see: https://github.com/openshift/knative-serving/blob/release-next/openshift/release/knative-serving-ci.yaml
  # So mount the manifest and use it by KO_DATA_PATH env value.
  patch -u ${CATALOG_SOURCE} < openshift/olm/config_map.patch

  oc apply -n $OLM_NAMESPACE -f ${CATALOG_SOURCE}
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Deploy Serverless Operator
  deploy_serverless_operator

  # Wait for the CRD to appear
  timeout 900 '[[ $(oc get crd | grep -c knativeservings) -eq 0 ]]' || return 1

  # Install Knative Serving with initial values in test/config/config-observability.yaml.
  cat <<-EOF | oc apply -f -
apiVersion: operator.knative.dev/v1alpha1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: ${SERVING_NAMESPACE}
spec:
  config:
    observability:
      logging.request-log-template: '{"httpRequest": {"requestMethod": "{{.Request.Method}}",
        "requestUrl": "{{js .Request.RequestURI}}", "requestSize": "{{.Request.ContentLength}}",
        "status": {{.Response.Code}}, "responseSize": "{{.Response.Size}}", "userAgent":
        "{{js .Request.UserAgent}}", "remoteIp": "{{js .Request.RemoteAddr}}", "serverIp":
        "{{.Revision.PodIP}}", "referer": "{{js .Request.Referer}}", "latency": "{{.Response.Latency}}s",
        "protocol": "{{.Request.Proto}}"}, "traceId": "{{index .Request.Header "X-B3-Traceid"}}"}'
      logging.enable-probe-request-log: "true"
EOF

  # Wait for 4 pods to appear first
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 4 ]]' || return 1
  wait_until_pods_running $SERVING_NAMESPACE || return 1

  wait_until_service_has_external_ip $SERVING_INGRESS_NAMESPACE kourier || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVING_INGRESS_NAMESPACE kourier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Knative Installed successfully"
}

function deploy_serverless_operator(){
  local name="serverless-operator"
  local operator_ns
  operator_ns=$(kubectl get og --all-namespaces | grep global-operators | awk '{print $1}')

  # Create configmap to use the latest manifest.
  oc create configmap ko-data -n $operator_ns --from-file="openshift/release/knative-serving-ci.yaml"

  # Create configmap to use the latest kourier.
  oc create configmap kourier-cm -n $operator_ns --from-file="third_party/kourier-latest/kourier.yaml"

  cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}-subscription
  namespace: ${operator_ns}
spec:
  source: ${name}
  sourceNamespace: $OLM_NAMESPACE
  name: ${name}
  channel: "preview-4.6"
EOF
}


# function install_serverless(){
#   header "Installing Serverless Operator"
#   git clone --branch release-1.6 https://github.com/openshift-knative/serverless-operator.git /tmp/serverless-operator
#   # unset OPENSHIFT_BUILD_NAMESPACE as its used in serverless-operator's CI environment as a switch
#   # to use CI built images, we want pre-built images of k-s-o and k-o-i
#   unset OPENSHIFT_BUILD_NAMESPACE
#   /tmp/serverless-operator/hack/install.sh || return 1
#   header "Serverless Operator installed successfully"
# }

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

function run_e2e_tests(){
  header "Running tests with Multi Tenant Channel Based Broker"
  k get ns ${TEST_EVENTING_NAMESPACE} 2>/dev/null || TEST_EVENTING_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${TEST_EVENTING_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} > tmp.tracing.config.yaml
  kubectl replace -f tmp.tracing.config.yaml
  rm tmp.tracing.config.yaml
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1beta1:Channel,messaging.knative.dev/v1beta1:InMemoryChannel,messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1alpha2:ApiServerSource,sources.knative.dev/v1alpha2:ContainerSource,sources.knative.dev/v1alpha2:PingSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG --imagetemplate $TEST_IMAGE_TEMPLATE"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  go_test_e2e -timeout=90m -parallel=12 ./test/e2e \
    "$run_command" \
    -brokerclass=MTChannelBasedBroker \
    $common_opts || failed=$?

  return $failed
}
