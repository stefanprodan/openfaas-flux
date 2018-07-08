
# Getting started with OpenFaaS Kubernetes Operator on EKS

The OpenFaaS team has recently released a Kubernetes operator for OpenFaaS. 
For an overview of why and how we created the operator head to Alex Ellis blog and read the [Introducing the OpenFaaS Operator for Serverless on Kubernetes](https://blog.alexellis.io/introducing-the-openfaas-operator/). 

My post is a step-by-step guide on running OpenFaaS with the operator on top of Amazon managed Kubernetes service.

The OpenFaaS Operator comes with an extension to the Kubernetes API that allows you to manage OpenFaaS functions
in a declarative manner. The operator implements a control loop that tries to match the desired state of your 
OpenFaaS functions defined as a collection of custom resources with the actual state of your cluster. 

![openfaas-operator](docs/screens/openfaas-operator.png)

### Setup a Kubernetes cluster with eksctl

In order to create an EKS cluster you can use [eksctl](https://eksctl.io). 
Eksctl is an open source command-line made by Weaveworks in collaboration with Amazon, 
it's written in Go and based on EKS CloudFormation templates.

On MacOS you can install eksctl with Homebrew:

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

Connect to the EKS cluster using the generated credential file:

```bash
export KUBECONFIG=$PWD/kubeconfig.openfaas.yaml
kubectl get nodes
```

You will be using Helm to install OpenFaaS, for Helm to work with EKS you need version 2.9.1 or newer.

Install Helm CLI with Homebrew:

```bash
brew install kubernetes-helm
```

Create a service account and cluster role binding for Tiller:

```bash
kubectl -n kube-system create sa tiller

kubectl create clusterrolebinding tiller-cluster-rule \
    --clusterrole=cluster-admin \
    --serviceaccount=kube-system:tiller 
```

Deploy Tiller on EKS:

```bash
helm init --skip-refresh --upgrade --service-account tiller
```

### Install OpenFaaS with Helm

Create the OpenFaaS namespaces:

```bash
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
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

Find the gateway address (it could take some time for the ELB to be online):

```yaml
export OPENFAAS_URL=$(kubectl -n openfaas describe svc/gateway-external | grep Ingress | awk '{ print $NF }'):8080
```

You can access the OpenFaaS UI at `http://OPENFAAS_URL` using the admin credentials. 

Install the OpenFaaS CLI and use the same credentials to login:

```bash
curl -sL https://cli.openfaas.com | sudo sh

echo $password | faas-cli login -u admin --password-stdin
```

### Manage OpenFaaS functions with kubectl 

Using the OpenFaaS CRD you can define functions as a Kubernetes custom resource:

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

### Conclusion 

The OpenFaaS Operator offers more options on managing functions on top of Kubernetes.
Besides faas-cli and the OpenFaaS UI now you can use kubectl, Helm charts and Weave Flux to build your 
continuous deployment pipelines. 

If you have questions about the operator please join the `#kubernetes` channel on 
[OpenFaaS Slack](https://docs.openfaas.com/community/).  

