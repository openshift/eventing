# Dockerfile to bootstrap build and test in openshift-ci

FROM registry.ci.openshift.org/openshift/release:golang-1.16

# Add kubernetes repository
ADD openshift/ci-operator/build-image/kubernetes.repo /etc/yum.repos.d/

RUN yum install -y kubectl ansible httpd-tools

RUN GO111MODULE=on go get github.com/mikefarah/yq/v3

# Allow runtime users to add entries to /etc/passwd
RUN chmod g+rw /etc/passwd
