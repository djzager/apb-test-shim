#!/bin/bash

# Idea and code snippets taken from:
# https://gist.github.com/geerlingguy/73ef1e5ee45d8694570f334be385e181

# Exit on any individual command failure.
set -e

# Pretty colors.
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
neutral='\033[0m'

apb_name=${apb_name:-"test-apb"}

function run_apb() {
    local image=$1
    local namespace=$2
    local action=$3

	printf ${green}"Running ${action} playbook"${neutral}"\n"
	docker run --rm --net=host -v $HOME/.kube:/opt/apb/.kube:z -u $UID $image $action --extra-vars "namespace=$namespace"
}

printf ${yellow}"Setting up docker for insecure registry"${neutral}"\n"
sudo apt-get update -qq
sudo sed -i "s/\DOCKER_OPTS=\"/DOCKER_OPTS=\"--insecure-registry=172.30.0.0\/16 /g" /etc/default/docker
sudo cat /etc/default/docker
sudo service docker restart
printf "\n"

printf ${yellow}"Installing requirements"${neutral}"\n"
pip install --pre ansible apb yamllint
printf "\n"

printf ${green}"Linting apb.yml"${neutral}"\n"
yamllint apb.yml
printf "\n"

printf ${green}"Building apb"${neutral}"\n"
apb build --tag $apb_name
if ! git diff --exit-code
	then printf ${red}"Committed APB spec differs from built apb.yml spec"${neutral}"\n"
    exit 1
fi

printf ${green}"Linting playbooks"${neutral}"\n"
playbooks=$(find playbooks -type f -printf "%f\n" -name '*.yml' -o -name '*.yaml')
if [ -z "$playbooks" ]; then
    printf ${red}"No playbooks"${neutral}"\n"
    exit 1
fi
for playbook in $playbooks; do
    docker run --entrypoint ansible-playbook $apb_name /opt/apb/actions/$playbook --syntax-check
done
printf "\n"

printf ${green}"Testing APB"${neutral}"\n"

printf ${yellow}"Bringing up openshift cluster, log in, and create project"${neutral}"\n"
sudo docker cp $(docker create docker.io/openshift/origin:$OPENSHIFT_VERSION):/bin/oc /usr/local/bin/oc
oc cluster up --version=$OPENSHIFT_VERSION
oc login -u system:admin
oc new-project $apb_name

printf ${green}"Provision APB"${neutral}"\n"
run_apb $apb_name $apb_name provision $test_idempotence
oc get all -n $apb_name

printf ${green}"Deprovision APB"${neutral}"\n"
run_apb $apb_name $apb_name deprovision $test_idempotence
oc get all -n $apb_name
printf "\n"

if [ -f "$PWD/tests/test.yml" ]; then
    # TODO: Run test playbook(s)
    printf ${green}"Test playbook exists"${neutral}"\n"
else
    printf ${yellow}"No test playbook"${neutral}"\n"
fi
