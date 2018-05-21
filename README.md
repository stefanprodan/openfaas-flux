# OpenFaaS GitOps workflow with Weave Flux 

This is a step by step guide on setting up a GitOps workflow for OpenFaaS with Weave Flux. 
GitOps is a way to do Continuous Deliver, it works by using Git as a source of truth for 
declarative infrastructure and workloads. 
In practice this means using `git push` instead of `kubectl create/apply` or `helm install/upgrade`. 

OpenFaaS (Functions as a Service) is Serverless Functions Made Simple for Docker and Kubernetes. 
With OpenFaaS you can package any container or binary as a serverless function - from Node.js to Golang to C# on 
Linux or Windows. 

Weave Flux is a GitOps Operator for Kubernetes that keeps your cluster state is sync with a Git repository.
Because Flux is pull based and runs inside Kubernetes you don't have to expose the cluster 
credentials outside your production environment. 
Once you enable Flux on your cluster any changes in your production environment are done via pull request with 
rollback and audit logs provided by Git. 

You can define the desire state of your cluster with Helm charts, Kubernetes deployments, network policies and 
even custom resources like OpenFaaS functions or sealed secrets. Weave Flux implements a control loop that continuously 
applies the desired state on your cluster offering protection against harmful actions like deployments deletion or 
network policies altering. 

### Install Weave Flux with Helm

Add Weave Flux chart repo:

```bash
helm repo add sp https://stefanprodan.github.io/k8s-podinfo
```

Install Weave Flux and its Helm Operator by specifying your fork URL 
(replace `stefanprodan` with your GitHub username): 

```bash
helm install --name weave-flux \
--set helmOperator.create=true \
--set git.url=git@github.com:stefanprodan/openfaas-flux \
--set git.chartsPath=charts \
--namespace flux \
sp/weave-flux
```

You can connect Weave Flux to Weave Cloud using a service token:

```bash
helm install --name weave-flux \
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
kubectl -n flux logs deployment/weave-flux | grep identity.pub | cut -d '"' -f2 | sed 's/.\{2\}$//'
```

In order to sync your cluster state with git you need to copy the public key and 
create a **deploy key** with **write access** on your GitHub repository.

Open GitHub and fork this repo, navigate to your fork, go to _Setting > Deploy keys_ click on _Add deploy key_, check 
_Allow write access_, paste the Flux public key and click _Add key_.

After a couple of seconds Flux
* creates the `openfaas` and `openfaas-fn` namespaces
* installs OpenFaaS Helm release
* creates the OpenFaaS functions

Check OpenFaaS services deployment status:

```
kubectl -n openfaas get deployments
NAME           DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
gateway        1         1         1            1           49s
nats           1         1         1            1           49s
prometheus     1         1         1            1           49s
queue-worker   3         3         3            3           49s
```

At this stage the gateway is not exposed outside the cluster. 
For testing purposes you can access the UI on your local machine at `http://localhost:8080` with port forwarding:

```bash
kubectl -n openfaas port-forward deployment/gateway 8080:8080
```

Before you expose OpenFaaS on the internet you need to secure the web UI and the OpenFaaS `/system` API.

### Manage Helm releases with Weave Flux

The Flux Helm operator provides an extension to Weave Flux to be able to automate Helm Chart releases.
A Chart release is described through a Kubernetes custom resource named `FluxHelmRelease`.
The Flux daemon synchronises these resources from git to the cluster,
and the Flux Helm operator makes sure Helm charts are released as specified in the resources.

![helm](docs/screens/flux-helm.png)

OpenFaaS release definition:

```yaml
apiVersion: helm.integrations.flux.weave.works/v1alpha2
kind: FluxHelmRelease
metadata:
  name: openfaas
  namespace: openfaas
  labels:
    chart: openfaas
spec:
  chartGitPath: openfaas
  releaseName: openfaas
  values:
    exposeServices: false
    rbac: true
    queueWorker:
      replicas: 3
    autoscaling:
      enabled: false
    images:
      gateway: functions/gateway:0.8.0
      prometheus: prom/prometheus:v2.2.0
      alertmanager: prom/alertmanager:v0.15.0-rc.1
      nats: nats-streaming:0.6.0
      queueWorker: functions/queue-worker:0.4.3
      operator: functions/faas-o6s:0.4.0
```

Flux Helm release fields:
* `metadata.name` is mandatory and needs to follow k8s naming conventions
* `metadata.namespace` is optional and determines where the release is created
* `metadata.labels.chart` is mandatory and should match the directory containing the chart
* `spec.releaseName` is optional and if not provided the release name will be `$namespace-$name`
* `spec.chartGitPath` is the directory containing the chart, given relative to the charts path
* `spec.values` are user customizations of default parameter values from the chart itself

### Manage OpenFaaS functions and auto-scaling with Weave Flux

An OpenFaaS function is describe through a Kubernetes custom resource named `function`.
The Flux daemon synchronises these resources from git to the cluster,
and the OpenFaaS Operator creates for each function a Kubernetes deployment and a ClusterIP service as 
specified in the resources.

![functions](docs/screens/flux-openfaas.png)

OpenFaaS function definition:

```yaml
apiVersion: o6s.io/v1alpha1
kind: Function
metadata:
  name: sentimentanalysis
  namespace: openfaas-fn
spec:
  name: sentimentanalysis
  image: functions/sentimentanalysis
  environment:
    output: "verbose"
  limits:
    cpu: "2000m"
    memory: "512Mi"
  requests:
    cpu: "10m"
    memory: "64Mi"
```

Since sentiment analysis is a ML function you would probably want to auto-scale it based on resource usage. 
You can use Kubernetes  horizontal pod autoscaler to automatically scale a function based on average CPU usage and 
memory consumption. 

```yaml
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: sentimentanalysis
  namespace: openfaas-fn
spec:
  scaleTargetRef:
    apiVersion: apps/v1beta2
    kind: Deployment
    name: sentimentanalysis
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      targetAverageUtilization: 50
  - type: Resource
    resource:
      name: memory
      targetAverageValue: 400Mi
```

Let's run a load test to validate that HPA works as expected: 

```bash
go get -u github.com/rakyll/hey
hey -n 100000 -c 10 -q 1 -d "$(cat README.md)" http://localhost:8080/function/sentimentanalysis
``` 

Monitor the autoscaler with:

```bash
kubectl -n openfaas-fn describe hpa

Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  SuccessfulRescale  12m   horizontal-pod-autoscaler  New size: 1; reason: All metrics below target
  Normal  SuccessfulRescale  4m    horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale  1m    horizontal-pod-autoscaler  New size: 8; reason: cpu resource utilization (percentage of request) above target
```

Running functions on a schedule can be done with Kubernetes ConJobs and the OpenFaaS CLI:

```yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: cron-nodeinfo
  namespace: openfaas
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: faas-cli
            image: openfaas/faas-cli:0.6.9
            args:
            - /bin/sh
            - -c
            - echo "verbose" | ./faas-cli invoke nodeinfo -g http://gateway:8080
          restartPolicy: OnFailure
```

The above cron job will call the `nodeinfo` function every minute using `verbose` as payload.

### Manage Secretes with Bitnami Sealed Secrets Controller and Weave Flux

On the first Git sync, Flux will deploy the Bitnami Sealed Secrets Controller. 
Sealed-secrets is a Kubernetes Custom Resource Definition Controller which allows you to store 
sensitive information in Git.

![SealedSecrets](docs/screens/flux-secrets.png)

In order to encrypt secrets you have to install the `kubeseal` CLI:

```bash
release=$(curl --silent "https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
GOOS=$(go env GOOS)
GOARCH=$(go env GOARCH)
wget https://github.com/bitnami/sealed-secrets/releases/download/$release/kubeseal-$GOOS-$GOARCH
sudo install -m 755 kubeseal-$GOOS-$GOARCH /usr/local/bin/kubeseal
```

Navigate to `./secrets` dir and delete all files inside. 

```bash
rm -rf secrets && mkdir secrets
```

At startup Sealed Secrets Controller generates a RSA key and logs the public key. 
Using `kubeseal` you can save your public key as `pub-cert.pem`, 
the public key can be safely stored in Git, you can use it to encrypt secrets **offline**:

```bash
kubeseal --fetch-cert \
--controller-namespace=flux \
--controller-name=sealed-secrets \
> secrets/pub-cert.pem
```

Next let's create a secret with the basic auth credentials for OpenFaaS Gateway. 

First with kubectl generate the basic-auth secret locally:

```bash
password=$(head -c 12 /dev/random | shasum| cut -d' ' -f1)
echo $password

kubectl -n openfaas create secret generic basic-auth \
--from-literal=user=admin \
--from-literal=password=$password \
--dry-run \
-o json > basic-auth.json
```

Encrypt the secret with kubeseal and save it in the `secrets` dir:

```bash
kubeseal --format=yaml --cert=secrets/pub-cert.pem < basic-auth.json > secrets/basic-auth.yaml
```

This will generate a custom resource of type `SealedSecret` that contains the encrypted credentials:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: basic-auth
  namespace: openfaas
spec:
  encryptedData:
    password: AgAR5nzhX2TkJ.......
    user: AgAQDO58WniIV3gTk.......
``` 

Finally delete the `basic-auth.json` file and commit your changes:

```bash
rm basic-auth.json
git add . && git commit -m "Add OpenFaaS basic auth credentials" && git push
```

The Flux daemon will apply the sealed secret on your cluster, the Sealed Secrets Controller will decrypt it into a 
Kubernetes secret.

### Expose OpenFaaS Gateway outside the cluster

Inside the [ingress](ingress) dir you can find a deployment definition for Caddy.
Caddy acts as a reverse proxy for the OpenFaaS Gateway and uses the `basic-auth` secret to protect the 
Gateway system API and UI. In order to deploy Caddy edit all manifest in the ingress dir and delete the 
`flux.weave.works/ignore` annotation.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: caddy-lb
  namespace: openfaas
  labels:
    app: caddy
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  selector:
    app: caddy
```

Commit your changes:

```bash
git add . && git commit -m "Enable OpenFaaS Caddy" && git push
```

You can access OpenFaaS Gateway using the LoadBalancer pubic IP 
(depending on your cloud provider this can take several minutes):

```bash
openfaas-ip=$(kubectl -n openfaas describe service caddy-lb | grep Ingress | awk '{ print $NF }')
```

Wait for an external IP to be allocated and then use it to access the OpenFaaS Gateway UI
with your credentials at `http://$openfaas-ip`.

Next you can enable TLS with LE by editing the Caddy [config](ingress/caddy-cfg.yaml) file.

If you run Kubernetes on-prem or on bare-metal you should change the Caddy service from LoadBalancer to 
NodePort to expose OpenFaaS on the internet.

### Manage Network Policies with Weave Flux

If you use a CNI like Weave Net or Calico that supports network policies you can enforce traffic rules for OpenFaaS 
by placing `NetworkPolicy` definitions inside the `network-policies` dir. 
The Flux daemon will apply the policies on your cluster along with the namespaces labels.

![NetworkPolicy](docs/screens/network-policy.png)

Deny ingress access to functions except from namespaces with `role: openfaas-system` label:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openfaas-fn
  namespace: openfaas-fn
spec:
  policyTypes:
  - Ingress
  podSelector: {}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          role: openfaas-system
```

Allow OpenFaaS core services to reach the `openfaas-fn` namespace by applying the `role: openfaas-system` label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openfaas
  labels:
    role: openfaas-system
    access: openfaas-system
```

Deny ingress access to OpenFaaS core services except from namespaces with `access: openfaas-system` label:

```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: openfaas
  namespace: openfaas
spec:
  policyTypes:
  - Ingress
  podSelector: {}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          access: openfaas-system
```

Allow Weave Cloud to scrape the OpenFaaS Gateway by applying the `access: openfaas-system` label to `weave` namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: weave
  labels:
    access: openfaas-system
```

### Disaster Recovery 

In order to recover from a major disaster like a cluster wipe out all you need to to is create a new Kubernetes cluster, 
deploy Flux with Helm and update the SSH public key in the GitHub repo. 
Weave Flux will restore all workloads on the new cluster, the only manifests that will fail to apply will be the sealed 
secrets since the private key used for decryption has changed. 

To prepare for disaster recovery you should backup the SealedSecrets private key with:

```bash
kubectl get secret -n flux sealed-secrets-key -o yaml --export > sealed-secrets-key.yaml
```

To restore from backup after a disaster replace the newly-created secret and restart the sealed-secrets controller:

```bash
kubectl replace secret -n flux sealed-secrets-key sealed-secrets-key.yaml
kubectl delete pod -n flux -l app=sealed-secrets
```

Once the correct private key is in place, the sealed-secrets controller will create the Kubernetes secrets and your 
OpenFaaS cluster will be fully restored.

