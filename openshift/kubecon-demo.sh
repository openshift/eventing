#!/bin/bash

readonly DEMO_URL="https://raw.githubusercontent.com/openshift-cloud-functions/demos/master/knative-kubecon"

function run_demo(){
  header "Running Knative Build/Serving/Eventing Demo"
  
  oc import-image -n openshift golang --from=centos/go-toolset-7-centos7 --confirm
  oc import-image -n openshift golang:1.11 --from=centos/go-toolset-7-centos7 --confirm
  
  oc new-project myproject

  oc adm policy add-cluster-role-to-user cluster-admin -z default -n myproject
  oc adm policy add-scc-to-user anyuid -z default -n myproject
  oc adm policy add-scc-to-user privileged -z default -n myproject

  apply build/000-rolebinding.yaml
  apply eventing/000-rolebinding.yaml
  
  apply build/010-build-template.yaml
  apply serving/010-service.yaml

  wait_for_all_pods myproject    

  local ip=$(oc get svc knative-ingressgateway -n istio-system -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')
  
  # Check that the helloworld app can server requests
  curl -H "Host: helloworld-openshift.myproject.example.com" "http://${ip}/health" || return 1

  apply eventing/010-channel.yaml
  apply eventing/020-k8s-event-source.yaml
  apply eventing/030-subscription.yaml

  wait_for_all_pods myproject  
  
  kubectl run busybox --image=busybox --restart=Never -- sh

  # Check that events arrive at the application
  wait_for_logged_events
}

function apply(){
  local yaml_path=$1
  curl -L ${DEMO_URL}/${yaml_path} | oc apply -f -
}

function delete(){
  local yaml_path=$1
  curl -L ${DEMO_URL}/${yaml_path} | oc delete -f -
}

function delete_demo(){
  delete build/000-rolebinding.yaml
  delete eventing/000-rolebinding.yaml
  oc delete project myproject
}

function wait_for_all_pods {
  timeout 300 "oc get pods -n $1 2>&1 | grep -v -E '(Running|Completed|STATUS)'"
}

function wait_for_logged_events(){
  POD=$(oc get pods | grep helloworld-openshift-00001-deployment | awk '{ print $1 }')
  timeout 300 "! oc logs $POD -c user-container | grep -E \"Ce-Source: .*pods/busybox\""
}

function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && exit -1
  done
}
