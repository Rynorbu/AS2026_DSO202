## Practical 6: Helm

### Stage 0: Install Helm and prepare the cluster

![alt text](assets/cluster_info.png)

### Install Helm 4

I have installed Helm 4 already on my local machine. Just checked the version.

![alt text](assets/heml_ver.png)

### Check Helm's config paths:

![alt text](assets/helm_path.png)

### Confirm Helm can reach the cluster

![alt text](assets/helm_list.png)

### Create the lab folder

## Stage 1: Use a published chart (podinfo)

### Add the repo and update it

![alt text](assets/helm_add_update.png)

### Search

![alt text](assets/helm_search.png)

### Read the chart before installing:

![alt text](assets/heml_search1.png)

### Install

![alt text](assets/helm_install.png)

### List releases

![alt text](assets/helm_list1.png)

### Check objects and access the app

![alt text](assets/pods.png)

In one terminal, I have port-forwarded the pod to access the app.

![alt text](assets/port_forwarding.png)

And in another terminal, I have accessed the app using curl.

![alt text](assets/curl_message.png)

Then Inspected the release and checked the logs.

![alt text](assets/inspect_release.png)

I have also checked the release records secrets.

![alt text](assets/inspect_secrets.png)

### Failure demo, the "lost values" upgrade:

![alt text](assets/failure_demo.png)


Fix it by using the `--reuse-values` flag.

![alt text](assets/fix_issue.png)

### Rollback and history

![alt text](assets/rollback.png)

![alt text](assets/history.png)

### Uninstall

![alt text](assets/uninstalled.png)

### Install from an OCI registry

![alt text](assets/install_oci.png)

After that I have uninstalled the release.

## Stage 2: Build our own chart skeleton (webapp)

![alt text](assets/scaffold.png)

After that, I have created the chart and checked the files. Then I have deleted the default templates and created my own templates for the webapp.

![alt text](assets/render.png)

Render a single file.

![alt text](assets/render_single.png)

### Values precedence and merging

![alt text](assets/value.png)

![alt text](assets/layering.png)

![alt text](assets/reverse_order.png)



![alt text](assets/set_vs_set-string.png)

## Validation (four failures and fixes)

### Failure 1: missing required value

![alt text](assets/failure1.png)

![alt text](assets/failure1.1.png)

### Failure 2: indentation

![alt text](assets/failure2.png)

### Failure 3: number instead of string

![alt text](assets/failure3.png)

Here I have created a file called `values.schema.json`. Helm validates the merged values against it on every install, upgrade, lint and template, before any template is rendered.

![alt text](assets/failure3.1.png)

### Failure 4: misspelled Kubernetes field

Here in the deployment.yaml file, I have misspelled the `replicas` field as `replica`. This is a Kubernetes field and Helm does not validate it. So, I have to check the Kubernetes documentation to find the correct spelling.

![alt text](assets/failure4.png)

### Final check for both environments:

![alt text](assets/check.png)

