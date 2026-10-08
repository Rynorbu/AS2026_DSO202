# Practical 6: Packaging and Deploying Kubernetes Apps with Helm

## Aim

To learn how to use **Helm** to install and manage apps on Kubernetes, and then build my own Helm chart (`webapp`) that runs an nginx web page on a local kind cluster.

## Objectives

- Install Helm 4 and connect it to a 3-node kind cluster.
- Add a chart repository and use it to search, install, upgrade, roll back and uninstall an app.
- See how Helm saves the history of every release inside the cluster.
- Write my own chart using `Chart.yaml`, `values.yaml` and templates.
- Use values files and `--set` to make different settings for **dev** and **prod**.
- Check a chart for mistakes using `required`, a JSON schema, `helm lint`, `helm template` and a dry run.

## What is Helm? (Simple Theory)

**Helm is like an app store / package manager for Kubernetes.** Just like `apt` installs software on Ubuntu, Helm installs applications on Kubernetes.

Key words to know:

| Word | Simple meaning |
|---|---|
| **Chart** | A package. It is a folder of Kubernetes YAML templates plus default settings. |
| **Values** | The settings you give to the chart (for example: number of replicas, image tag, message). |
| **Release** | One installed copy of a chart in the cluster, with a name you choose. |
| **Revision** | A version number of a release. Every install, upgrade or rollback adds a new revision. |
| **Repository** | A place online where charts are stored and shared. |

### Why do we need Helm?

If we use only `kubectl apply -f`, we face these problems:

- We copy the same YAML again and again for dev, test and prod.
- There is no version number for the whole app.
- We cannot easily undo (roll back) a bad change.
- Deleted files leave old objects behind in the cluster.
- There is no easy way to share the app with others.

Helm fixes all of these with **templates, versioned charts, release history and repositories**.

### What Helm does NOT do

- It does not build Docker images.
- It does not keep watching the cluster to fix changes (that is the job of GitOps tools like Argo CD).
- It does not hide secrets. Values are saved in the cluster and can be read.
- It does not test if your app actually works. It only checks that Kubernetes accepted the objects.

## Tools and Environment

| Item | Details |
|---|---|
| Operating system | Windows with WSL 2 (Ubuntu) |
| Container runtime | Docker |
| Cluster | kind cluster named `dso202` (1 control-plane + 2 workers) |
| Kubernetes | v1.36.1 |
| Helm | v4.3 |
| Editor | VS Code / nano |

---

## Procedure

### Stage 0: Install Helm and Prepare the Cluster

First I checked that the cluster is running.

![cluster info](assets/cluster_info.png)

The context is `kind-dso202` and all three nodes are **Ready**.

**Check the Helm version** (Helm 4 was already installed on my machine):

![helm version](assets/heml_ver.png)

**Check where Helm keeps its files** (cache, config and data):

![helm paths](assets/helm_path.png)

**Check that Helm can talk to the cluster:**

![helm list](assets/helm_list.png)

The list is empty, which is correct because nothing is installed yet.

---

### Stage 1: Use a Published Chart (podinfo)

#### 1. Add the repository and update it

![helm repo add](assets/helm_add_update.png)

- `helm repo add` only saves the repository URL.
- `helm repo update` downloads the latest list of charts (`index.yaml`).

#### 2. Search for the chart

![helm search](assets/helm_search.png)

#### 3. Read the chart before installing

![helm show values](assets/heml_search1.png)

It is good practice to read the chart's values first. Installing a chart without reading it is like running unknown code on your cluster.

#### 4. Install the chart

![helm install](assets/helm_install.png)

I installed podinfo with 2 replicas and a custom message: `Hello from DSO202`.

#### 5. List the releases

![helm list](assets/helm_list1.png)

The second command shows nothing because releases belong to a **namespace**. My release was installed in its own namespace, not in `default`, so I must add `-n <namespace>` (or `-A` for all namespaces).

#### 6. Check the pods and open the app

![pods](assets/pods.png)

I used port-forwarding in a second terminal:

![port forwarding](assets/port_forwarding.png)

Then I used `curl` in another terminal:

![curl message](assets/curl_message.png)

The reply shows `"message": "Hello from DSO202"`. This proves my `--set` value reached the running app.

#### 7. Inspect the release

![inspect release](assets/inspect_release.png)

- `helm get values` shows only the values **I** gave.
- `helm get values --all` shows **all** values (mine + defaults).
- `helm get manifest` shows the final YAML that was sent to Kubernetes.

Helm saves every revision as a **Secret** in the cluster:

![release secrets](assets/inspect_secrets.png)

#### 8. Failure demo: "lost values" during upgrade

![failure demo](assets/failure_demo.png)

The upgrade worked, but the replicas went from **2 back to 1** and my custom message **disappeared**.

**Why?** When you run `helm upgrade` with any new value, Helm starts again from the chart defaults and only adds the values in that command. The old values are forgotten.

**Fix:** use `--reuse-values` (or better, always pass the same values file).

![fix issue](assets/fix_issue.png)

#### 9. Rollback and history

![rollback](assets/rollback.png)

![history](assets/history.png)

Rollback does **not** delete revisions 2 and 3. It creates a **new revision 4** that is a copy of revision 1. So the full history is always kept.

#### 10. Uninstall

![uninstall](assets/uninstalled.png)

All app objects and history were removed, but the **namespace stays**. `--create-namespace` creates the namespace, but it is not part of the release, so Helm does not delete it.

#### 11. Install from an OCI registry

![install oci](assets/install_oci.png)

With OCI, there is no need for `helm repo add`. The full address is written in the command. Many companies like this because charts and Docker images can live in the same registry. After testing, I uninstalled this release.

---

### Stage 2: Build My Own Chart (webapp)

![scaffold](assets/scaffold.png)

`helm create` makes a big starter chart. I only used it as a reference and wrote a **smaller chart by hand** so I understand every line.

I created `Chart.yaml`, `values.yaml` and `.helmignore`.

### Stage 3: Write the Templates

I wrote these templates: `_helpers.tpl`, `configmap.yaml`, `deployment.yaml`, `service.yaml`, `NOTES.txt` and a test pod.

Then I rendered the chart to see the final YAML without installing it:

![render](assets/render.png)

**What I noticed:**

1. Helm sorts objects by type (ConfigMap → Service → Deployment → test Pod), not by file order.
2. The name is `webapp-dev`, not `webapp-dev-webapp`, because the release name already has the chart name in it.
3. `toYaml` sorts keys, so `limits` comes before `requests`.
4. The checksum annotation is always the same for the same input. When the ConfigMap changes, the checksum changes and the pods restart.
5. The image became `nginx:1.30-alpine` because `image.tag` was empty, so Helm used `appVersion` from `Chart.yaml`.

Render only one file:

![render single](assets/render_single.png)

---

### Stage 4: Values Order and Merging

Helm reads values in this order (**last one wins**):

1. The chart's own `values.yaml` (lowest)
2. Files given with `-f` (from left to right, the right-most file wins)
3. `--set` flags (highest, always win)

Rules for merging:

- **Maps** (key: value groups) are merged key by key.
- **Lists and single values** are replaced completely.
- Setting a key to `null` removes it.

![values](assets/value.png)

![layering](assets/layering.png)

![reverse order](assets/reverse_order.png)

Changing the order of `-f` files changes the result.

![set vs set-string](assets/set_vs_set-string.png)

`--set` guesses the type (for example `1.30` becomes the number `1.3`). `--set-string` always keeps it as text.

---

### Stage 5: Validation (4 Failures and Fixes)

#### Failure 1: Missing required value

![failure 1](assets/failure1.png)

The `required` function stopped the render with my own error message. The error points to the test pod file only because that file uses the helper. **Read the message, not just the file name.**

![failure 1.1](assets/failure1.1.png)

`helm lint` only gave a **warning** and still passed (exit code 0), even with `--strict`. So a CI pipeline using only lint would miss this mistake.

#### Failure 2: Wrong indentation

![failure 2](assets/failure2.png)

I used `indent` in the wrong way, so only the first line was indented and the YAML broke. **Fix:** `{{- toYaml .Values.resources | nindent 12 }}`.

#### Failure 3: Number instead of text

![failure 3](assets/failure3.png)

I created `values.schema.json`. Helm checks all values against this schema **before** rendering, on every install, upgrade, lint and template.

![failure 3.1](assets/failure3.1.png)

Now a wrong type (number instead of string) is caught with a clear error.

#### Failure 4: Spelling mistake in a Kubernetes field

In `deployment.yaml` I wrote `replica` instead of `replicas`. Helm does not know Kubernetes fields, so `helm template` and `helm lint` did **not** catch it. Only a server-side dry run with `kubectl` found it.

![failure 4](assets/failure4.png)

#### Final check for both environments

![final check](assets/check.png)

Both dev and prod now pass all checks.

---

## Reflection

### What I learned

Before this practical, I deployed apps on Kubernetes by writing many YAML files and running `kubectl apply`. Now I understand how Helm turns those files into one package that I can install, upgrade and roll back with one command. The idea of a **release** and **revisions** was new to me, and it made me see an app as one unit instead of many separate objects. I also learned how Go templates, named helpers in `_helpers.tpl`, and values files work together so that one chart can be used for both dev and prod.

### Challenges I faced

- **The "lost values" upgrade surprised me.** The upgrade said it was successful, but my replicas and custom message were gone. I learned that "success" in Helm only means Kubernetes accepted the objects, not that my settings were kept. Using `--reuse-values`, or better, always passing the same values file, fixed it.
- **Indentation in templates was confusing.** A small mistake with `indent` vs `nindent` broke the whole YAML. I had to render the chart with `helm template` many times to see the real output.
- **`helm lint` did not catch everything.** I expected lint to fail when a required value was missing, but it only gave a warning. The misspelled `replica` field also passed Helm checks. Only the `kubectl` server-side dry run caught it.
- **Values merging order** took time to understand. When I changed the order of `-f` files, I got a different result, which showed me why the order matters.

### How I solved them

I read the error messages carefully, rendered single templates with `--show-only`, compared outputs, and checked the Helm and Kubernetes documentation. I added a `values.schema.json` so that wrong types are caught early, and I used several validation steps together instead of trusting only one.

### How this will help me in the future

In real DevOps work, the same app is deployed to many environments. Helm will help me keep one chart and only change small values files for each environment. I now know some important safety rules: never put passwords in values, always pass all values on upgrade, keep values files in Git, and use more than one validation step in a CI pipeline. I also understand that Helm is not a full GitOps tool, so in future I want to learn how tools like Argo CD use Helm charts to keep the cluster in sync automatically.

### Overall

This practical was very useful. Making mistakes on purpose and fixing them taught me more than just following the steps. I now feel confident to write, test and deploy my own Helm charts.

---

## Conclusion

In this practical I learned the full Helm workflow. With the podinfo chart, I added a repository, installed, upgraded, rolled back and uninstalled an app, and saw how Helm keeps history as Secrets. Then I built my own `webapp` chart from scratch with helpers, labels, a checksum annotation and separate dev and prod values. Finally, I made four common mistakes on purpose and fixed them using different validation tools. The main lesson is: **Helm makes Kubernetes apps easy to version, repeat and roll back, but you must manage values carefully and check your chart in more than one way.**