
# Getting started with OpenFaaS Kubernetes Operator 

The OpenFaaS Operator is an extension to the Kubernetes API that allows you to manage OpenFaaS functions
in a declarative manner. The OpenFaaS Operator implements a control loop that tries to match the desired state of your 
OpenFaaS functions defined as a collection of custom resources with the actual state of your cluster. 

The OpenFaaS Operator is a drop-in replacement of the faas-netes controller. Some of the advantages of switching to the Operator are:

* declarative API (Operator) vs imperative API (faas-netes)
* use kubectl and/or faas-cli for functions CRUD operations (Operator) vs faas-cli only (faas-netes)
* on deletion, functions are garbage collected by the Kubernetes API (Operator) vs explicit deletion of a function deployment and ClusterIP service (faas-netes)
* query the function status via the Kubernetes API (Operator) vs query the status using faas-netes HTTP API
* due to the reconciliation loop the Operator can handle transient Kubernetes API outages while faas-netes has no retry mechanism

![openfaas-operator](docs/screens/openfaas-operator.png)

### Setup a Kubernetes cluster 

Since Amazon just launched their hosted Kubernetes service let's try it out. 
You will need to have AWS API credentials configured.

First install [eksctl](https://eksctl.io), a simple CLI tool for creating clusters:

```bash
brew install weaveworks/tap/eksctl
```

You will also need heptio-authenticator-aws:

```bash
curl -o heptio-authenticator-aws https://amazon-eks.s3-us-west-2.amazonaws.com/1.10.3/2018-06-05/bin/darwin/amd64/heptio-authenticator-aws
chmod +x ./heptio-authenticator-aws
sudo mv ./heptio-authenticator-aws /usr/local/heptio-authenticator-aws
```

Create a EKS cluster with:

```bash
eksctl create cluster --name=openfaas \
    --nodes=2 \
    --region=us-west-2 \
    --node-type=m5.xlarge \
    --kubeconfig=./kubeconfig.openfaas.yaml
```

Use the cluster credentials with kubectl:

```bash
export KUBECONFIG=$PWD/kubeconfig.openfaas.yaml
kubectl get nodes
```

You will be using Helm to install OpenFaaS, for Helm to work with EKS you need v2.9.1 or latest.

Install Helm CLI:

```bash
brew install kubernetes-helm
```

Create a service account for Tiller:

```bash
kubectl -n kube-system create sa tiller
```

Create a cluster role binding for Tiller:

```bash
kubectl create clusterrolebinding tiller-cluster-rule \
    --clusterrole=cluster-admin \
    --serviceaccount=kube-system:tiller 
```

Deploy Tiller in kube-system namespace:

```bash
helm init --skip-refresh --upgrade --service-account tiller
```

### Install OpenFaaS with Helm

Create the OpenFaaS namespaces:

```bash
kubectl create namespace openfaas && \
kubectl create namespace openfaas-fn
```

Generate a random password and create OpenFaaS credentials secret:

```bash
password=$(head -c 12 /dev/urandom | shasum| cut -d' ' -f1)

kubectl -n openfaas create secret generic basic-auth \
--from-literal=basic-auth-user=admin \
--from-literal=basic-auth-password=$password
```

Install OpenFaaS:

```bash
helm repo add openfaas https://openfaas.github.io/faas-netes/

helm upgrade openfaas --install openfaas/openfaas \
    --namespace openfaas  \
    --set functionNamespace=openfaas-fn \
    --set serviceType=LoadBalancer \
    --set basic_auth=true \
    --set operator.create=true
```

Find the gateway address and login with faas-cli (it could take some time for the ELB to be online):

```yaml
export OFELB=$(kubectl -n openfaas describe svc/gateway-external | grep Ingress | awk '{ print $NF }')
echo $password | faas-cli login -u admin -g $OFELB:8080 --password-stdin
```

You can access the OpenFaaS UI at `http://$OFELB:8080/ui` using the admin credentials. 

### Manage OpenFaaS function with kubectl 

Using the OpenFaaS Operator you can define functions as a Kubernetes custom resource:

```yaml
apiVersion: openfaas.com/v1alpha2
kind: Function
metadata:
  name: certinfo
  namespace: openfaas-fn
spec:
  name: certinfo
  image: stefanprodan/certinfo:latest
  # translates to Kubernetes metadata.labels
  labels:
    # if you plan to use Kubernetes HPA v2 
    # delete the min/max labels and 
    # set the factor to 0 to disable auto-scaling based on req/sec
    com.openfaas.scale.min: "2"
    com.openfaas.scale.max: "12"
    com.openfaas.scale.factor: "4"
  # translates to Kubernetes container.env
  environment:
    output: "verbose"
    debug: "true"
  # secrets are mounted as readonly files at /var/openfaas/
  # if you use a private registry add your image pull secret to the list 
  secrets:
    - my-key
    - my-token
  # translates to Kubernetes resources.limits
  limits:
    cpu: "1000m"
    memory: "128Mi"
  # translates to Kubernetes resources.requests
  requests:
    cpu: "10m"
    memory: "64Mi"
  # translates to Kubernetes nodeSelector
  constraints:
    - "beta.kubernetes.io/arch=amd64"
```

Save the above resource as `certinfo.yaml` and use kubectl to deploy the function:

```bash
kubectl -n openfaas-fn apply -f certinfo.yaml
```

Since certinfo requires the `my-key` and `my-token` secrets, the Operator will not be able to create a deployment but 
will keep retrying.
You can view the operator logs with:

```bash
kubectl -n openfaas logs deployment/gateway -c operator

controller.go:215] error syncing 'openfaas-fn/certinfo': secret "my-key" not found
```

Let's create the secrets:

```bash
kubectl -n openfaas-fn create secret generic my-key --from-literal=my-key=demo-key
kubectl -n openfaas-fn create secret generic my-token --from-literal=my-token=demo-token
```

Once the secrets are in place the Operator will proceed with the certinfo deployment. You can get the status of the 
running functions with:

```yaml
kubectl -n openfaas-fn get functions
NAME                AGE
certinfo            4m

kubectl -n openfaas-fn get deployments
NAME                DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
certinfo            1         1         1            1           1m
```

Test that secrets are available inside the certinfo pod at `var/openfaas/`:

```bash
export CERT_POD=$(kubectl get pods -n openfaas-fn -l "app=certinfo" -o jsonpath="{.items[0].metadata.name}")
kubectl -n openfaas-fn exec -it $CERT_POD -- sh

~ $ cat /var/openfaas/my-key 
demo-key

~ $ cat /var/openfaas/my-token 
demo-token
``` 

You can delete a function with:

```bash
kubectl -n openfaas-fn delete function certinfo
```



