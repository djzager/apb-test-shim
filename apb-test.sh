#!/bin/bash

# Idea and code snippets taken from:
# https://gist.github.com/geerlingguy/73ef1e5ee45d8694570f334be385e181

# Exit on any individual command failure.
set -ex

# Pretty colors.
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
neutral='\033[0m'

apb_name=${apb_name:-"test-apb"}
dockerfile=${dockerfile:-"Dockerfile"}
cluster_role=${cluster_role:-"edit"}
binding=${binding:-"rolebinding"}

# Lock Helm version until latest is functional
DESIRED_HELM_VERSION="v2.8.2"

function run_apb() {
    local action=$1
    local pod_name="$apb_name-$action"

    printf ${green}"Run $action Playbook"${neutral}"\n"
    echo -en 'travis_fold:start:'$pod_name'\\r'
    $CMD run "$pod_name" \
        --namespace=$apb_name \
        --env="POD_NAME=$pod_name" \
        --env="POD_NAMESPACE=$apb_name" \
        --image=$apb_name \
        --image-pull-policy=Never \
        --restart=Never \
        --attach=true \
        --serviceaccount=$apb_name \
        -- $action -e namespace=$apb_name -e cluster=$CLUSTER
    printf "\n"
    $CMD get all -n $apb_name
    echo -en 'travis_fold:end:'$pod_name'\\r'
    printf "\n"
}

function setup_openshift() {
    printf ${green}"Testing APB in OpenShift"${neutral}"\n"
    echo -en 'travis_fold:start:openshift\\r'
    printf ${yellow}"Setting up docker for insecure registry"${neutral}"\n"
    sudo apt-get update -qq
    sudo sed -i "s/\DOCKER_OPTS=\"/DOCKER_OPTS=\"--insecure-registry=172.30.0.0\/16 /g" /etc/default/docker
    sudo cat /etc/default/docker
    sudo iptables -F
    sudo service docker restart
    printf "\n"

    printf ${yellow}"Bringing up an openshift cluster and logging in"${neutral}"\n"
    sudo docker cp $(docker create docker.io/openshift/origin:$OPENSHIFT_VERSION):/bin/oc /usr/local/bin/oc
    sudo curl -Lo /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    sudo chmod +x /usr/bin/kubectl
    if [ "$OPENSHIFT_VERSION" == "latest" ] || [ "${OPENSHIFT_VERSION:0:5}" == "v3.10" ]; then
        oc cluster up \
            --routing-suffix=172.17.0.1.nip.io \
            --public-hostname=172.17.0.1 \
            --tag=$OPENSHIFT_VERSION \
            --enable=service-catalog,template-service-broker,router,registry,web-console,persistent-volumes,sample-templates,rhel-imagestreams
    else
        oc cluster up \
            --routing-suffix=172.17.0.1.nip.io \
            --public-hostname=172.17.0.1 \
            --version=$OPENSHIFT_VERSION \
            --service-catalog=true
    fi
    echo -en 'travis_fold:end:openshift\\r'
    printf "\n"

    oc login -u system:admin

    # Use for cluster operations
    export CMD=oc
    export CLUSTER=openshift
    alias kubectl='oc'
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
    curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | DESIRED_VERSION=$DESIRED_HELM_VERSION bash

    export MINIKUBE_WANTUPDATENOTIFICATION=false
    export MINIKUBE_WANTREPORTERRORPROMPT=false
    export MINIKUBE_HOME=$HOME
    export CHANGE_MINIKUBE_NONE_USER=true
    mkdir $HOME/.kube || true
    touch $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config

    if [ "$KUBERNETES_VERSION" == "latest" ]; then
        sudo minikube start \
            --vm-driver=none \
            --bootstrapper=localkube \
            --extra-config=apiserver.Authorization.Mode=RBAC
    else
        sudo minikube start \
            --vm-driver=none \
            --bootstrapper=localkube \
            --extra-config=apiserver.Authorization.Mode=RBAC \
            --kubernetes-version=$KUBERNETES_VERSION
    fi
    minikube update-context

    # this for loop waits until kubectl can access the api server that Minikube has created
    for i in {1..150}; do # timeout for 5 minutes
      kubectl get po &> /dev/null && break
      sleep 2
    done

    # Install service-catalog
    helm init --wait
    kubectl create clusterrolebinding tiller-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:default
    helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
    helm install svc-cat/catalog --name catalog --namespace catalog
    # Wait until the catalog is ready before moving on
    until kubectl get pods -n catalog -l app=catalog-catalog-apiserver | grep 2/2; do sleep 1; done
    until kubectl get pods -n catalog -l app=catalog-catalog-controller-manager | grep 1/1; do sleep 1; done

    echo -en 'travis_fold:end:minikube\\r'
    printf "\n"

    # Use for cluster operations
    export CMD=kubectl
    export CLUSTER=kubernetes
    alias oc='kubectl'
}

function requirements() {
    printf ${yellow}"Installing requirements"${neutral}"\n"
    echo -en 'travis_fold:start:install_requirements\\r'
    if [ -z "$TRAVIS_PYTHON_VERSION" ]; then
        export PATH=$HOME/.local/bin:$PATH
        pip install --pre apb yamllint --user `whoami`
    else
        pip install --pre apb yamllint
    fi

    # Install nsenter
    docker run --rm jpetazzo/nsenter cat /nsenter > /tmp/nsenter 2> /dev/null; sudo cp /tmp/nsenter /usr/local/bin/; sudo chmod +x /usr/local/bin/nsenter; which nsenter
    echo -en 'travis_fold:end:install_requirements\\r'
    printf "\n"
}

function lint_apb() {
    printf ${green}"Linting apb.yml"${neutral}"\n"
    echo -en 'travis_fold:start:lint.1\\r'
    yamllint apb.yml
    echo -en 'travis_fold:end:lint.1\\r'
    printf "\n"
}

function build_apb() {
    printf ${green}"Building apb"${neutral}"\n"
    echo -en 'travis_fold:start:build.1\\r'
    apb build --tag $apb_name -f $dockerfile
    if ! git diff --exit-code
        then printf ${red}"Committed APB spec differs from built apb.yml spec"${neutral}"\n"
        exit 1
    fi
    echo -en 'travis_fold:end:build.1\\r'
    printf "\n"
}

function lint_playbooks() {
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
}

function setup_cluster() {
    if [ -n "$OPENSHIFT_VERSION" ]; then
        setup_openshift
    elif [ -n "$KUBERNETES_VERSION" ]; then
        setup_kubernetes
    else
        printf ${red}"No cluster environment variables set"${neutral}"\n"
        exit 1
    fi
}

function create_apb_namespace() {
    if [ -n "$OPENSHIFT_VERSION" ]; then
        oc new-project $apb_name
    elif [ -n "$KUBERNETES_VERSION" ]; then
        kubectl create namespace $apb_name
    else
        printf ${red}"No cluster environment variables set"${neutral}"\n"
        exit 1
    fi
    $CMD get namespace $apb_name -o yaml
}

function create_sa() {
    printf ${yellow}"Get enough permissions for APB to run"${neutral}"\n"
    $CMD create serviceaccount $apb_name --namespace=$apb_name
    $CMD create $binding $apb_name \
        --namespace=$apb_name \
        --clusterrole=$cluster_role \
        --serviceaccount=$apb_name:$apb_name
    $CMD get serviceaccount $apb_name --namespace=$apb_name -o yaml
    $CMD get $binding $apb_name --namespace=$apb_name -o yaml
    sleep 5
    printf "\n"
}

# Run the test
function test_apb() {
    requirements
    lint_apb
    build_apb
    lint_playbooks
    setup_cluster
    create_apb_namespace
    create_sa
    run_apb "test"
}

# Allow the functions to be loaded, skipping the test run
if [ -z $SOURCE_ONLY ]; then
    test_apb
fi
