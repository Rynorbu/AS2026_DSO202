## Practical 6: Packaging and Deploying Kubernetes Applications with Helm

## AIM

To use Helm, the package manager for Kubernetes, to install and manage a published chart, and then to build, configure and validate a custom Helm chart (webapp) that deploys an nginx web page to a local kind cluster.

## Objectives
 
- Install Helm v4 and connect it to a three-node kind cluster.
- Add a chart repository, then search, inspect, install, upgrade, roll back and uninstall a release.
- Understand how Helm stores release history as Secrets inside the cluster.
- Write a chart from scratch using `Chart.yaml`, `values.yaml`, Go templates and named templates.
- Use values files and `--set` flags to configure dev and prod environments, and understand precedence and merging.
- Validate a chart with `required`, a JSON values schema, `helm lint`, `helm template` and server-side dry runs.


## Background Theory

**Helm** is the package manager for Kubernetes and a graduated CNCF project. It bundles Kubernetes manifest templates and default configuration into a versioned package called a **chart**, renders that chart with user-supplied **values**, and applies the result to a cluster as a named **release**. Every change to a release is recorded as a numbered **revision**, so the whole application can be upgraded, inspected, rolled back or removed as one unit.

### Problems Helm solves
 
Plain `kubectl apply -f` manifests suffer from duplication across environments, no application-level version, no group rollback, orphaned objects when files are deleted, and no distribution format. Helm addresses all five through templating, versioned charts, release history and repositories.
 
### What Helm does not do
 
Helm does not build container images, does not continuously reconcile the cluster (that is the job of GitOps tools), does not keep secrets secret (values are stored in the release record), and does not prove the application works beyond the API server accepting the objects.


## Environment and Tools

| Component | Version / Detail |
|---|---|
| Host OS | Windows with WSL 2 (Ubuntu) |
| Container runtime | Docker |
| Cluster | kind, cluster name `dso202` (1 control-plane, 2 workers) |
| Kubernetes | v1.36.1 (`kindest/node:v1.36.1`) |
| Helm | v4.3 |
| Editor | VS Code / nano |

## Procedure

### Stage 0: Install Helm and prepare the cluster

![alt text](assets/cluster_info.png)

The context is kind-dso202 and all three nodes report Ready. kind names the nodes dso202-control-plane, dso202-worker and dso202-worker2.

### Install Helm 4

I have installed Helm 4 already on my local machine. Just checked the version.

![alt text](assets/heml_ver.png)

### Check Helm's config paths:

![alt text](assets/helm_path.png)

### Confirm Helm can reach the cluster

![alt text](assets/helm_list.png)

## Stage 1: Use a published chart (podinfo)

### Add the repo and update it

![alt text](assets/helm_add_update.png)

helm repo add only records the URL. Helm repo update downloads the repository's index.yaml into the local cache.

### Search

![alt text](assets/helm_search.png)

### Read the chart before installing:

![alt text](assets/heml_search1.png)

The values file is the chart's configuration interface. Installing an unread chart would mean running unreviewed code with my own cluster permissions.

### Install

![alt text](assets/helm_install.png)


### List releases

![alt text](assets/helm_list1.png)

The second command shows nothing because releases belong to a namespace and the current namespace is default.

### Check objects and access the app

![alt text](assets/pods.png)

In a second terminal the Deployment was port-forwarded, then queried with `curl`

![alt text](assets/port_forwarding.png)

And in another terminal, I have accessed the app using curl. The response contains "message": "Hello from DSO202", proving the --set override reached the running application.

![alt text](assets/curl_message.png)

Then Inspected the release and checked the logs.

![alt text](assets/inspect_release.png)

helm get values shows only user-supplied values, --all shows the merged values, and helm get manifest shows the exact YAML sent to the API server.

I have also checked the release records secrets.

![alt text](assets/inspect_secrets.png)

### Failure demo, the "lost values" upgrade:

![alt text](assets/failure_demo.png)

The upgrade succeeded, but replicas dropped from 2 to 1 and the custom message disappeared. When helm upgrade receives any value flag, it starts from the chart defaults and applies only that command's values, silently discarding the values given at install time.

**Fix it by using the `--reuse-values` flag.**

![alt text](assets/fix_issue.png)

### Rollback and history

![alt text](assets/rollback.png)

![alt text](assets/history.png)

The rollback did not delete revisions 2 and 3. It created revision 4 ("Rollback to 1") containing a copy of revision 1, so the history remains a complete, ordered record.

### Uninstall

![alt text](assets/uninstalled.png)

All objects and release records were removed, but the namespace remained Active, because --create-namespace does not make the namespace part of the release.

### Install from an OCI registry

![alt text](assets/install_oci.png)

An OCI reference needs no helm repo add; the full location is given in the command. Organisations increasingly prefer OCI registries because images and charts can share one registry and one access-control system.

After that I have uninstalled the release.

## Stage 2: Build our own chart skeleton (webapp)

![alt text](assets/scaffold.png)

The Helm 4 scaffold includes httproute.yaml for the Gateway API alongside ingress.yaml. It was used for reference only, and a smaller chart was written by hand so each line is understood.

The files Chart.yaml, values.yaml and .helmignore were then created.

![alt text](assets/render.png)

**Observations from the render:**

1. Objects are ordered by kind (ConfigMap, Service, Deployment, test Pod), not by file order.
2. The object name is webapp-dev, not webapp-dev-webapp, because the release name already contains the chart name.
toYaml sorted limits before requests.
3. The checksum is deterministic: the same input always gives the same hash.
4. The image resolved to nginx:1.30-alpine from appVersion, because image.tag is empty.

Render a single file.

![alt text](assets/render_single.png)

### Values precedence and merging

Values are merged in this order (lowest to highest priority):
 
1. The chart's `values.yaml`
2. Files given with `-f`, left to right (rightmost wins)
3. `--set` flags (always override every `-f` file)
Maps merge deeply key by key; lists and scalars are replaced entirely; setting a key to `null` deletes it.


![alt text](assets/value.png)

![alt text](assets/layering.png)

![alt text](assets/reverse_order.png)

![alt text](assets/set_vs_set-string.png)

## Validation (four failures and fixes)

### Failure 1: missing required value

![alt text](assets/failure1.png)

The `required` function in `webapp.environment` stopped rendering with the chart's own message. The reported location is the test Pod because it *includes* the helper, so the message text, not the file name, identifies the cause.

![alt text](assets/failure1.1.png)

`helm lint` reported the missing value only as a **warning** and exited with code **0**, even with `--strict`. A CI pipeline relying on lint alone would pass this broken chart.

### Failure 2: indentation

![alt text](assets/failure2.png)

Only the first line of the `toYaml` output received indentation; the rest started at column zero, producing invalid YAML. The line was restored to `{{- toYaml .Values.resources | nindent 12 }}`.

### Failure 3: number instead of string

![alt text](assets/failure3.png)

Here I have created a file called `values.schema.json`. Helm validates the merged values against it on every install, upgrade, lint and template, before any template is rendered.

![alt text](assets/failure3.1.png)

### Failure 4: misspelled Kubernetes field

Here in the deployment.yaml file, I have misspelled the `replicas` field as `replica`. This is a Kubernetes field and Helm does not validate it. So, I have to check the Kubernetes documentation to find the correct spelling.

![alt text](assets/failure4.png)

### Final check for both environments:

![alt text](assets/check.png)

## Observations and Analysis
 
1. **Upgrades can silently lose configuration.** Passing only some values to `helm upgrade` discards the rest. This is a common cause of production incidents, and is avoided by keeping all values in version-controlled files and passing them on every upgrade.
2. **Rollback appends, it does not rewrite.** Rolling back to revision 1 created revision 4, so the audit trail is never lost.
3. **Helm stores values in plain sight.** The release record Secret contains every supplied value, so passwords must never be placed in values files or `--set` flags.
4. **Uninstall does not remove the namespace** created with `--create-namespace`.
5. **Layering environment files leaks settings** between environments, because maps merge deeply.
6. **YAML and `--set` change types silently** (`1.30` becomes `1.3`, `true` becomes a boolean). A values schema catches these before anything reaches the cluster.
7. **No single validation tool is enough.** `helm lint` misses required values and unknown fields; only a server-side `kubectl` dry run catches misspelled Kubernetes fields.

## 10. Conclusion
 
This practical demonstrated the full Helm workflow. Using the published podinfo chart, I added a repository, inspected, installed, upgraded, rolled back and uninstalled a release, and saw how Helm records each revision as a Secret in the cluster. I then built the `webapp` chart from scratch, using named templates, the recommended label set, a checksum annotation and per-environment values files. Finally, I reproduced four realistic failures and showed how `required`, a JSON values schema and server-side dry runs each catch different classes of error. The key lesson is that Helm makes Kubernetes applications versioned, repeatable and easy to roll back, but it must be combined with disciplined values management and layered validation to be safe in production.
