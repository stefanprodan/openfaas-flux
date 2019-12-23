# OpenFaaS GitOps workflow with Weave Flux 

This is a step-by-step guide on how to set up a GitOps workflow for OpenFaaS with Flux CD and its Helm Operator. 
GitOps is a way to do Continuous Delivery, it works by using Git as a source of truth for 
declarative infrastructure and workloads. In practice this means using `git push` instead of `kubectl create/apply` or `helm install/upgrade`. 

OpenFaaS (Functions as a Service) is Serverless Functions Made Simple for Docker and Kubernetes. 
With OpenFaaS you can package any container or binary as a serverless function - from Node.js to Golang to C# on 
Linux or Windows. 

Flux is a GitOps Operator for Kubernetes that keeps your cluster state is sync with a Git repository.
Because Flux is pull based and also runs inside Kubernetes, you don't have to expose the cluster 
credentials outside your production environment.
Once you enable Flux on your cluster any changes in your production environment are done via
pull request with rollback and audit logs provided by Git. 

You can define the desired state of your cluster with Helm charts, Kubernetes deployments, network policies and 
even custom resources like OpenFaaS functions or sealed secrets. Flux implements a control loop that continuously 
applies the desired state to your cluster, offering protection against harmful actions like deployments deletion or 
policies altering.

### Prerequisites

You'll need a Kubernetes cluster v1.11 or newer with load balancer support, a GitHub account, git and kubectl installed locally.

Install Helm v3 and fluxctl for macOS:

```sh
brew install helm fluxctl
```

For Windows:

```sh
choco install kubernetes-helm fluxctl
```

On GitHub, fork the [openfaas-flux](https://github.com/stefanprodan/openfaas-flux) repository and clone it locally
(replace `stefanprodan` with your GitHub username): 

```sh
git clone https://github.com/stefanprodan/openfaas-flux
cd openfaas-flux
```

### Install Flux and Helm Operator

Add FluxCD repository to Helm repos:

```bash
helm repo add fluxcd https://charts.fluxcd.io
```

Create the `fluxcd` namespace:

```sh
kubectl create ns fluxcd
```

Install Flux by specifying your fork URL (replace `stefanprodan` with your GitHub username): 

```bash
helm upgrade -i flux fluxcd/flux --wait \
--namespace fluxcd \
--set git.url=git@github.com:stefanprodan/openfaas-flux 
```

Install the `HelmRelease` Kubernetes custom resource definition:

```sh
kubectl apply -f https://raw.githubusercontent.com/fluxcd/helm-operator/master/deploy/flux-helm-release-crd.yaml
```

Install Flux Helm Operator with Helm v3 support:

```bash
helm upgrade -i helm-operator fluxcd/helm-operator --wait \
--namespace fluxcd \
--set git.ssh.secretName=flux-git-deploy \
--set extraEnvs[0].name=HELM_VERSION \
--set extraEnvs[0].value=v3 \
--set image.repository=fluxcd/helm-operator-prerelease \
--set image.tag=master-df100c55
```

### Setup Git sync

At startup, Flux generates a SSH key and logs the public key. Find the public key with:

```bash
fluxctl identity --k8s-fwd-ns fluxcd
```

In order to sync your cluster state with git you need to copy the public key and 
create a **deploy key** with **write access** on your GitHub repository.

Open GitHub, navigate to your repository, go to _Settings > Deploy keys_ click on _Add deploy key_, check 
_Allow write access_, paste the Flux public key and click _Add key_.

After a couple of seconds Flux will create the `openfaas` and `openfaas-fn` namespaces and will install the OpenFaaS Helm release.

Check the OpenFaaS deployment status:

```
watch kubectl -n openfaas get helmrelease openfaas
```

Retrieve the OpenFaaS credentials with:

```sh
PASSWORD=$(kubectl -n openfaas get secret basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode) && \
echo "OpenFaaS admin password: $PASSWORD"
```

### Manage Helm releases with Flux

The Helm operator provides an extension to Flux that automates Helm chart releases.
A chart release is described through a Kubernetes custom resource named `HelmRelease`.
The Flux daemon synchronizes these resources from git to the cluster,
and the Helm operator makes sure Helm charts are released as specified in the resources.

![helm](docs/screens/flux-helm.png)

Let's take a look at the OpenFaaS definition by running `cat ./releases/openfaas.yaml` inside the git repo:

```yaml
apiVersion: helm.fluxcd.io/v1
kind: HelmRelease
metadata:
  name: openfaas
  namespace: openfaas
spec:
  releaseName: openfaas
  chart:
    repository: https://openfaas.github.io/faas-netes/
    name: openfaas
    version: 5.4.0
  values:
    generateBasicAuth: true
    exposeServices: false
    serviceType: LoadBalancer
    operator:
      create: true
```

The `spec.chart` section tells Flux Helm Operator where is the chart repository and what version to install.
The `spec.values` are user customizations of default parameter values from the chart itself.
Changing the version or a value in git, will make the Helm Operator upgrade the release.

Edit the release and set two replicas for the queue worker with:

```sh
cat << EOF | tee releases/openfaas.yaml
apiVersion: helm.fluxcd.io/v1
kind: HelmRelease
metadata:
  name: openfaas
  namespace: openfaas
spec:
  releaseName: openfaas
  chart:
    repository: https://openfaas.github.io/faas-netes/
    name: openfaas
    version: 5.4.0
  values:
    generateBasicAuth: true
    exposeServices: false
    serviceType: LoadBalancer
    operator:
      create: true
    queueWorker:
      replicas: 2
EOF
```

Apply changes via git:

```sh
git add -A && \
git commit -m "scale up queue worker" && \
git push origin master && \
fluxctl sync --k8s-fwd-ns fluxcd
```

Note that Flux does a git-cluster reconciliation every five minutes,
the `fluxctl sync` command can be used to speed up the synchronization.

Check that Helm Operator has upgraded the release and that the queue worker was scaled up:

```sh
watch kubectl -n openfaas get pods
```

### Manage OpenFaaS functions with Flux

An OpenFaaS function is described through a Kubernetes custom resource named `function`.
The Flux daemon synchronizes these resources from git to the cluster,
and the OpenFaaS Operator creates for each function a Kubernetes deployment and a ClusterIP service as 
specified in the resources.

![functions](docs/screens/flux-openfaas.png)

You'll use a chart to bundle multiple functions and manage the install and upgrade process.
