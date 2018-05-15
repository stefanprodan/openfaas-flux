# openfaas-flux

OpenFaaS Cluster state managed by Weave Flux

### Install Weave Flux 

Add Weave Flux chart repo:

```bash
helm repo add sp https://stefanprodan.github.io/k8s-podinfo
```

Install Weave Flux and its Helm Operator by specifying your fork URL 
(replace `stefanprodan` with your GitHub username): 

```bash
helm install --name cd \
--set helmOperator.create=true \
--set git.url=git@github.com:stefanprodan/openfaas-flux \
--set git.chartsPath=charts \
--namespace flux \
sp/weave-flux
```

You can connect Weave Flux to Weave Cloud using your service token:

```bash
helm install --name cd \
--set token=YOUR_WEAVE_CLOUD_SERVICE_TOKEN \
--set helmOperator.create=true \
--set git.url=git@github.com:stefanprodan/openfaas-flux \
--set git.chartsPath=charts \
--namespace flux \
sp/weave-flux
```

### Setup Git sync

At startup Flux generates a SSH key and logs the public key. 
Find the SSH public key with:

```bash
export FLUX_POD=$(kubectl get pods --namespace flux -l "app=weave-flux,release=cd" -o jsonpath="{.items[0].metadata.name}")
kubectl -n flux logs $FLUX_POD | grep identity.pub | cut -d '"' -f2 | sed 's/.\{2\}$//'
```

In order to sync your cluster state with git you need to copy the public key and 
create a **deploy key** with **write access** on your GitHub repository.

Open GitHub, navigate to your fork, go to _Setting > Deploy keys_ click on _Add deploy key_, check 
_Allow write access_, paste the Flux public key and click _Add key_.

After a couple of seconds Flux will
* create the `openfaas` and `openfaas-fn` namespaces 
* install OpenFaaS Helm release
* create the OpenFaaS functions

Check OpenFaaS services deployment status:

```
kubectl -n openfaas get deployments
NAME           DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
alertmanager   1         1         1            1           1m
gateway        1         1         1            1           1m
nats           1         1         1            1           1m
prometheus     1         1         1            1           1m
queue-worker   1         1         1            1           1m
```

Check OpenFaaS functions deployment status:

```
kubectl -n openfaas-fn get pods
NAME                        READY     STATUS    RESTARTS   AGE
nodeinfo-58c5bd8998-hxd4g   1/1       Running   0          26s
nodeinfo-58c5bd8998-v5zw6   1/1       Running   0          26s
```
