#!/bin/sh 

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh

set -x

# Using the most recent good release of eventing-sources to unblock tests. This
# should be replaced with the commented line below when eventing-sources nightly
# is known good again.
readonly KNATIVE_EVENTING_SOURCES_RELEASE=https://github.com/knative/eventing-sources/releases/download/v0.4.0/release.yaml
#readonly KNATIVE_EVENTING_SOURCES_RELEASE=https://knative-nightly.storage.googleapis.com/eventing-sources/previous/v20181205-fbac942/release.yaml
#readonly KNATIVE_EVENTING_SOURCES_RELEASE=https://knative-nightly.storage.googleapis.com/eventing-sources/latest/release.yaml

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="docker-registry.default.svc:5000"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-"~/.ssh/google_compute_engine"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly EVENTING_NAMESPACE=knative-eventing
readonly TEST_NAMESPACE=e2etest-knative-eventing

env

function enable_admission_webhooks(){
  header "Enabling admission webhooks"
  add_current_user_to_etc_passwd
  disable_strict_host_checking
  echo "API_SERVER=$API_SERVER"
  echo "KUBE_SSH_USER=$KUBE_SSH_USER"
  chmod 600 ~/.ssh/google_compute_engine
  echo "$API_SERVER ansible_ssh_private_key_file=${SSH_PRIVATE_KEY}" > inventory.ini
  ansible-playbook ${REPO_ROOT_DIR}/openshift/admission-webhooks.yaml -i inventory.ini -u $KUBE_SSH_USER
  rm inventory.ini
}

function add_current_user_to_etc_passwd(){
  if ! whoami &>/dev/null; then
    echo "${USER:-default}:x:$(id -u):$(id -g):Default User:$HOME:/sbin/nologin" >> /etc/passwd
  fi
  cat /etc/passwd
}

function disable_strict_host_checking(){
  cat >> ~/.ssh/config <<EOF
Host *
   StrictHostKeyChecking no
   UserKnownHostsFile=/dev/null
EOF
}

function install_istio(){
  header "Installing Istio"
  # Grant the necessary privileges to the service accounts Istio will use:
  oc adm policy add-scc-to-user anyuid -z istio-ingress-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z default -n istio-system
  oc adm policy add-scc-to-user anyuid -z prometheus -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-egressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-citadel-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-cleanup-old-ca-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-post-install-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-pilot-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-sidecar-injector-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z cluster-local-gateway-service-account -n istio-system
  oc adm policy add-cluster-role-to-user cluster-admin -z istio-galley-service-account -n istio-system
  
  # Deploy the latest Istio release
  oc apply -f $KNATIVE_ISTIO_CRD_YAML
  oc apply -f $KNATIVE_ISTIO_YAML

  # Ensure the istio-sidecar-injector pod runs as privileged
  oc get cm istio-sidecar-injector -n istio-system -o yaml | sed -e 's/securityContext:/securityContext:\\n      privileged: true/' | oc replace -f -
  # Monitor the Istio components until all the components are up and running
  wait_until_pods_running istio-system || return 1
  header "Istio Installed successfully"
}

function install_knative_serving(){
  header "Installing Knative Serving"

  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-scc-to-user anyuid -z controller -n knative-serving
  oc adm policy add-scc-to-user anyuid -z autoscaler -n knative-serving
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z controller -n knative-serving

  curl -L ${KNATIVE_SERVING_RELEASE} | sed '/nodePort/d' | oc apply -f -
  
  echo ">>> Setting SSL_CERT_FILE for Knative Serving Controller"
  oc set env -n knative-serving deployment/controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

  echo ">> Patching istio-ingressgateway"
  oc patch hpa -n istio-system istio-ingressgateway --patch '{"spec": {"maxReplicas": 1}}'

  wait_until_pods_running knative-build || return 1
  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"
  header "Knative Installed successfully"
}

function install_knative_eventing_sources(){
  header "Installing Knative Eventing Sources"
  oc apply -f ${KNATIVE_EVENTING_SOURCES_RELEASE}
  wait_until_pods_running knative-sources || return 1
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  # Create knative-eventing namespace, needed for imagestreams
  oc create namespace $EVENTING_NAMESPACE

  # Grant the necessary privileges to the service accounts Knative will use:
  oc annotate clusterrolebinding.rbac cluster-admin 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite
  oc annotate clusterrolebinding.rbac cluster-admins 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite

  oc adm policy add-scc-to-user anyuid -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-controller -n $EVENTING_NAMESPACE

  resolve_resources config/ $EVENTING_NAMESPACE eventing-resolved.yaml
  oc apply -f eventing-resolved.yaml

  oc adm policy add-cluster-role-to-user cluster-admin -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z default -n knative-sources

  echo ">>> Setting SSL_CERT_FILE for Knative Eventing Controller"
  oc set env -n $EVENTING_NAMESPACE deployment/eventing-controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

  wait_until_pods_running $EVENTING_NAMESPACE
}

function install_in_memory_channel_provisioner(){
  header "Standing up In-Memory ClusterChannelProvisioner"
  resolve_resources config/provisioners/in-memory-channel/ $EVENTING_NAMESPACE channel-resolved.yaml
  oc apply -f channel-resolved.yaml
}

function create_test_resources() {
  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_NAMESPACE --namespace=$EVENTING_NAMESPACE

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  > $resolved_file_name
  for yaml in $(find $dir -maxdepth 1 -name "*.yaml"); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's%github.com/knative/eventing/pkg/controller/eventing/inmemory/controller%'"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-in-memory-channel-controller%' | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-\4/' >> $resolved_file_name
  done

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${EVENTING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name}
  done
}

function enable_docker_schema2(){
  oc set env -n default dc/docker-registry REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_ACCEPTSCHEMA2=true
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=20m \
    ./test/e2e \
    --tag latest \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${EVENTING_NAMESPACE} \
    ${options} || return 1
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete --ignore-not-found=true -f ${KNATIVE_ISTIO_CRD_YAML}
  oc delete --ignore-not-found=true -f ${KNATIVE_ISTIO_YAML}
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f ${KNATIVE_SERVING_RELEASE}
}

function delete_test_namespace(){
  echo ">> Deleting test namespace $TEST_NAMESPACE"
  oc adm policy remove-scc-from-user privileged -z default -n $TEST_NAMESPACE
  oc delete project $TEST_NAMESPACE
}

function delete_knative_eventing_sources(){
  header "Brinding down Knative Eventing Sources"
  oc delete --ignore-not-found=true -f ${KNATIVE_EVENTING_SOURCES_RELEASE}
}

function delete_knative_eventing(){
  header "Bringing down Eventing"
  oc delete --ignore-not-found=true -f eventing-resolved.yaml
}

function delete_in_memory_channel_provisioner(){
  header "Bringing down In-Memory ClusterChannelProvisioner"
  oc delete --ignore-not-found=true -f channel-resolved.yaml
}

function teardown() {
  delete_test_namespace
  delete_in_memory_channel_provisioner
  delete_knative_eventing
  delete_knative_eventing_sources
  delete_serving_openshift
  delete_istio_openshift
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-eventing-test-${name} ${name}
  done
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  oc tag --insecure=${INSECURE} -n ${EVENTING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:latest
}

enable_admission_webhooks

install_istio

enable_docker_schema2

install_knative_serving

install_knative_eventing_sources

install_knative_eventing

install_in_memory_channel_provisioner

create_test_namespace

create_test_resources

failed=0

run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success