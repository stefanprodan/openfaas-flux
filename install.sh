set -eu

if [[ ! -x "$(command -v kubectl)" ]]; then
    echo "kubectl not found"
    exit 1
fi

if [ ! -x "$(command -v helm)" ]; then
    echo "helm not found"
    exit 1
fi

GH_USER=${1:-stefanprodan}
GH_REPO=${2:-openfaas-flux}
GH_BRANCH=${3:-master}
GH_URL="git@github.com:${GH_USER}/${GH_REPO}"
REPO_ROOT=$(git rev-parse --show-toplevel)

helm repo add fluxcd https://charts.fluxcd.io

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: fluxcd
EOF

helm upgrade -i flux fluxcd/flux --wait \
--namespace fluxcd \
--set git.url=${GH_URL} \
--set git.branch=${GH_BRANCH}

kubectl apply -f https://raw.githubusercontent.com/fluxcd/helm-operator/master/deploy/flux-helm-release-crd.yaml

helm upgrade -i helm-operator fluxcd/helm-operator --wait \
--namespace fluxcd \
--set git.ssh.secretName=flux-git-deploy \
--set helm.versions=v3

echo ""
echo "Configure GitHub deploy key for $GH_URL with write access:"
kubectl -n fluxcd logs deployment/flux | grep identity.pub | cut -d '"' -f2


