#This makefile is used by ci-operator

CGO_ENABLED=0
GOOS=linux
CORE_IMAGES=./cmd/apiserver_receive_adapter ./cmd/broker/ingress/ ./cmd/broker/filter/ ./cmd/controller/ ./cmd/cronjob_receive_adapter ./cmd/pong/ ./cmd/sendevent/ ./cmd/sources_controller ./cmd/webhook/
TEST_IMAGES=$(shell find ./test/test_images -mindepth 1 -maxdepth 1 -type d)

install:
	go install $(CORE_IMAGES)
	go build -o $(GOPATH)/bin/imc-controller ./cmd/in_memory/channel_controller
	go build -o $(GOPATH)/bin/imc-dispatcher ./cmd/in_memory/channel_dispatcher
	go build -o $(GOPATH)/bin/in-memory-channel-controller ./cmd/in_memory/controller
	go build -o $(GOPATH)/bin/in-memory-channel-dispatcher ./cmd/in_memory/dispatcher
.PHONY: install

test-install:
	for img in $(TEST_IMAGES); do \
		go install $$img ; \
	done
.PHONY: test-install

test-e2e:
	sh openshift/e2e-tests-openshift.sh
.PHONY: test-e2e

test-origin-conformance:
	sh TEST_ORIGIN_CONFORMANCE=true openshift/e2e-tests-openshift.sh
.PHONY: test-origin-conformance

# Generate Dockerfiles used by ci-operator. The files need to be committed manually.
generate-dockerfiles:
	# remove old shizzle to catch when images got removed!
	# rm -rf openshift/ci-operator/knative-images/*
	# rm -rf openshift/ci-operator/knative-test-images/*

	# regenerate the images...
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images $(CORE_IMAGES)
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images imc-controller
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images imc-dispatcher
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images in-memory-channel-controller
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images in-memory-channel-dispatcher
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-test-images $(TEST_IMAGES)
.PHONY: generate-dockerfiles

# Generate an aggregated knative yaml file with replaced image references
generate-release:
	./openshift/release/generate-release.sh $(RELEASE)
.PHONY: generate-release

# Generates a ci-operator configuration for a specific branch.
generate-ci-config:
	./openshift/ci-operator/generate-ci-config.sh $(BRANCH) > ci-operator-config.yaml
.PHONY: generate-ci-config
