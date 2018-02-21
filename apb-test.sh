#!/bin/bash

# Exit on any individual command failure.
set -e
# Show trace.
set -x

# Pretty colors.
red='\033[0;31m'
green='\033[0;32m'
neutral='\033[0m'

export ANSIBLE_ROLES_PATH=$ANSIBLE_ROLES_PATH:$PWD/roles

printf ${green}"Setting up docker for insecure registry"${neutral}"\n"
sudo apt-get update -qq
sudo sed -i "s/\DOCKER_OPTS=\"/DOCKER_OPTS=\"--insecure-registry=172.30.0.0\/16 /g" /etc/default/docker
sudo cat /etc/default/docker
sudo service docker restart
printf "\n"

printf ${green}"Installing requirements"${neutral}"\n"
pip install --pre ansible apb yamllint
printf "\n"

printf ${green}"Linting apb.yml"${neutral}"\n"
yamllint apb.yml
printf "\n"

printf ${green}"Verify committed APB spec matches Dockerfile"${neutral}"\n"
apb build
if ! git diff --exit-code
	then printf ${red}"Committed APB spec differs from built apb.yml spec"${neutral}"\n"
    exit 1
fi
printf "\n"

printf ${green}"Linting playbooks"${neutral}"\n"
for PLAYBOOK in playbooks/*.yml
	do ansible-playbook $PLAYBOOK --syntax-check
done
printf "\n"

printf ${green}"Testing APB"${neutral}"\n"
export APB_NAME=hello-world-apb
apb build
sudo docker cp $(docker create docker.io/openshift/origin:$OPENSHIFT_VERSION):/bin/oc /usr/local/bin/oc
oc cluster up --version=$OPENSHIFT_VERSION
oc login -u system:admin
oc new-project $APB_NAME
docker run --rm --net=host -v $HOME/.kube:/opt/apb/.kube:z -u $UID $APB_NAME provision --extra-vars "namespace=$APB_NAME"
oc get all -n $APB_NAME
docker run --rm --net=host -v $HOME/.kube:/opt/apb/.kube:z -u $UID $APB_NAME deprovision --extra-vars "namespace=$APB_NAME"
oc get all -n $APB_NAME
printf "\n"
