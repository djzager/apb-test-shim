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
    local action=$1
    local pod_name="$apb_name-$action"

    printf ${green}"Run $action Playbook"${neutral}"\n"
    $CMD run "$pod_name" \
        --namespace=$apb_name \
        --env="POD_NAME=$pod_name" \
        --env="POD_NAMESPACE=$apb_name" \
        --image=$apb_name \
        --image-pull-policy=Never \
        --restart=Never \
        --attach=true \
        --overrides='{ "spec": { "serviceAccountName": "'$apb_name'" } }' \
        -- $action -e namespace=$apb_name -e cluster=$CLUSTER || \
        if [ $? -eq 8 ] && [[ $action != *provision ]]; then
            printf ${yellow}"Optional action ($action) not implemented"${neutral}"\n"
        else
            printf ${red}"Run of $action Playbook FAILED"${neutral}"\n"
            exit $?
        fi

    printf "\n"
    $CMD get all -n $apb_name
    printf "\n"
}

function setup_openshift() {
    printf ${green}"Testing APB in OpenShift"${neutral}"\n"
    echo -en 'travis_fold:start:openshift\\r'
    printf ${yellow}"Setting up docker for insecure registry"${neutral}"\n"
    sudo apt-get update -qq
    sudo sed -i "s/\DOCKER_OPTS=\"/DOCKER_OPTS=\"--insecure-registry=172.30.0.0\/16 /g" /etc/default/docker
    sudo cat /etc/default/docker
    sudo service docker restart
    sudo iptables -F
    printf "\n"

    printf ${yellow}"Bringing up an openshift cluster and logging in"${neutral}"\n"
    sudo docker cp $(docker create docker.io/openshift/origin:$OPENSHIFT_VERSION):/bin/oc /usr/local/bin/oc
    oc cluster up --routing-suffix=172.17.0.1.nip.io --public-hostname=172.17.0.1 --version=$OPENSHIFT_VERSION
    oc login -u system:admin
    docker build -t $apb_name -f Dockerfile .
    oc new-project $apb_name
    echo -en 'travis_fold:end:openshift\\r'
    printf "\n"

    # Use for cluster operations
    CMD=oc
    CLUSTER=openshift
}

function setup_kubernetes() {
    printf ${green}"Setup: Testing APB in Kubernetes"${neutral}"\n"

    # https://github.com/kubernetes/minikube#linux-continuous-integration-without-vm-support
    printf ${yellow}"Bringing up minikube"${neutral}"\n"
    echo -en 'travis_fold:start:minikube\\r'
    sudo curl -Lo /usr/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo chmod +x /usr/bin/minikube
    sudo curl -Lo /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    sudo chmod +x /usr/bin/kubectl

    export MINIKUBE_WANTUPDATENOTIFICATION=false
    export MINIKUBE_WANTREPORTERRORPROMPT=false
    export MINIKUBE_HOME=$HOME
    export CHANGE_MINIKUBE_NONE_USER=true
    mkdir $HOME/.kube || true
    touch $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config

    if [ "$KUBERNETES_VERSION" == "latest" ]; then
        sudo minikube start --vm-driver=none
    else
        sudo minikube start --vm-driver=none --kubernetes-version=$KUBERNETES_VERSION
    fi
    minikube update-context
    docker build -t $apb_name -f Dockerfile .
    kubectl create namespace $apb_name
    echo -en 'travis_fold:end:minikube\\r'
    printf "\n"

    # Use for cluster operations
    CMD=kubectl
    CLUSTER=kubernetes
}

printf ${yellow}"Installing requirements"${neutral}"\n"
echo -en 'travis_fold:start:install_requirements\\r'
pip install --pre ansible apb yamllint
echo -en 'travis_fold:end:install_requirements\\r'
printf "\n"

printf ${green}"Linting apb.yml"${neutral}"\n"
echo -en 'travis_fold:start:lint.1\\r'
yamllint apb.yml
echo -en 'travis_fold:end:lint.1\\r'
printf "\n"

printf ${green}"Preparing apb"${neutral}"\n"
echo -en 'travis_fold:start:prepare.1\\r'
apb build --tag $apb_name
if ! git diff --exit-code
	then printf ${red}"Committed APB spec differs from built apb.yml spec"${neutral}"\n"
    exit 1
fi
echo -en 'travis_fold:end:prepare.1\\r'
printf "\n"

printf ${green}"Linting playbooks"${neutral}"\n"
echo -en 'travis_fold:start:lint.2\\r'
playbooks=$(find playbooks -type f -printf "%f\n" -name '*.yml' -o -name '*.yaml')
if [ -z "$playbooks" ]; then
    printf ${red}"No playbooks"${neutral}"\n"
    exit 1
fi
for playbook in $playbooks; do
    docker run --entrypoint ansible-playbook $apb_name /opt/apb/actions/$playbook --syntax-check
done
echo -en 'travis_fold:end:lint.2\\r'
printf "\n"

if [ -n "$OPENSHIFT_VERSION" ]; then
    setup_openshift
elif [ -n "$KUBERNETES_VERSION" ]; then
    setup_kubernetes
else
    printf ${red}"No cluster environment variables set"${neutral}"\n"
    exit 1
fi

# Get enough permissions for APB to run
printf ${yellow}"Creating project sandbox for APB"${neutral}"\n"
$CMD create serviceaccount -n $apb_name $apb_name
$CMD create clusterrolebinding $apb_name --clusterrole=cluster-admin --serviceaccount=$apb_name:$apb_name
printf "\n"

# Run the playbooks
for ACTION in "provision" "bind" "unbind" "deprovision" "test"; do
    run_apb $ACTION
done
