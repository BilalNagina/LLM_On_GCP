# Troubleshooting log

Real problems hit while building this lab on 2026-11-18, in the order they happened.

## 1. Bucket IAM binding failed: "Identity Pool does not exist"

**Symptom.** First `terraform apply` created the cluster and node pool, then failed:
`Error 400: Identity Pool does not exist (<PROJECT_ID>.svc.id.goog)`.

**Cause.** The binding grants `roles/storage.objectViewer` straight to the Kubernetes
ServiceAccount as a `principal://…/workloadIdentityPools/<project>.svc.id.goog/subject/ns/llm/sa/llm-server`.
That pool is created by GKE when the first cluster with Workload Identity comes up.
Terraform had no reason to order the binding after the cluster, so it ran while
the cluster was still being created.

**Fix.** `depends_on = [google_container_cluster.llm]` on the binding.

## 2. Re-apply replaced the whole cluster

**Symptom.** The next `terraform apply` destroyed and recreated the cluster and
node pool (about 15 min). It had been run with `-auto-approve`, so the
"must be replaced" lines weren't reviewed first.

**Cause.** `node_config` on `google_container_cluster` only describes the temporary
default pool, which `remove_default_node_pool = true` deletes. On the next plan the
provider sees drift on that block, and changing it forces replacement.

**Fix.** `lifecycle { ignore_changes = [node_config] }` on the cluster, then a
`terraform plan` showing "No changes". **Process fix:** always read the plan
before applying, and never `-auto-approve` against a stateful resource.

## 3. kubectl couldn't authenticate (no gke-gcloud-auth-plugin)

**Symptom.** `gcloud` in WSL is the apt package, so `gcloud components install`
is disabled and installing the plugin needs `sudo`.

**Fix.** Wrote a small exec credential plugin (`scripts/kubeconfig.sh`) that wraps
`gcloud auth print-access-token`, pinned to the lab gcloud configuration so it
can't pick up any other logged-in account.

## 4. llama-server crash loop: `invalid argument: --host=0.0.0.0`

**Cause.** llama.cpp's argument parser doesn't accept `--flag=value`.

**Fix.** Flag and value as separate list items. While both pods were broken, the
Deployment's `maxUnavailable: 0` stopped the rollout from removing old pods, so a
bad version can't take capacity away from a healthy one.

## 5. llama-server crash loop: `invalid argument: --no-mmap`

**Cause.** The mirrored `:server` image is llama.cpp build 12464, which replaced
`--no-mmap` with `--load-mode` (`auto|none|mmap|mmap+mlock`). Found by running the
pinned image with `--help` in a throwaway pod.

**Fix.** `--load-mode none`, which reads the weights into RAM instead of
memory-mapping them over GCS FUSE. It's also why the Deployment uses the image
**digest** recorded at import time, not the moving `:server` tag.

## 6. Zero-downtime test, first run: HPA wasn't actually held at 2 replicas

**Symptom.** The swap test patched the HPA to `min=max=2`, but HPA events showed
it scaling to 4 pods during the test, and the cluster autoscaler hit the node
pool's maximum of 4 nodes.

**Cause.** `deploy.sh` re-applies the whole manifest, HPA included, so every
deploy silently restored `2..6`.

**Fix.** HPA bounds became template variables (`HPA_MIN`/`HPA_MAX`) set by the test
script, and the run was repeated. The first run's logs are kept as
`results/raw/*run1-hpa-unpinned.log`.

## 7. Intermittent failed / stalled requests during model swaps

**Symptom.** Across the first six v1→v2 swap runs under load (1,804 requests),
3 requests failed with `EOF`, and several runs had one request stall for 70–90s.
The failures didn't line up with the hypothesis: 2 came **without** a preStop
hook, 1 **with** a 20s preStop, and two no-preStop runs had zero failures.
Load tests alone couldn't explain it.

**Diagnosis: a deterministic experiment** (`scripts/sigterm-test.sh`): send one
400-token generation (~20s) to a pod via port-forward, delete that pod 4–6s in.

| preStop | Result |
|---|---|
| 0s | no response; the connection **hung 85s** (= 90s grace period − 4s) until SIGKILL |
| 45s | **HTTP 200, all 400 tokens**, 21.9s, even though the pod was deleted at +6s |

**Cause.** On SIGTERM, llama-server stops generating but doesn't close the
connections it's serving. Anything still in flight at SIGTERM hangs until SIGKILL.
That explains both the EOFs and the 70–90s stalls. Whether a load-test run hit it
depended on whether an old pod happened to be mid-generation when SIGTERM arrived.
The 20s preStop failed because 256-token generations ran up to ~25s (p99), longer
than the hook.

**Partial fix.** `preStop` must outlast endpoint removal **plus the longest
generation**: raised to 45s, with `terminationGracePeriodSeconds: 90` above it.
That was necessary but not sufficient; see #8.

## 8. Failures still happened with a 45s preStop: keep-alive connections

**Symptom.** Swap test with 256 tokens and preStop 45s: 2 of 132 requests failed
with `EOF` at 08:37:11.

**Timeline from pod events.** Old pod deleted 08:35:41, so preStop runs until about
08:36:26, then SIGTERM, then SIGKILL at 08:37:11 (deletion + 90s grace). The failures
are at the **SIGKILL** second, which means the pod was still receiving new requests
45s after its endpoint had been removed.

**Cause.** Removing an endpoint from a Service only affects **new** TCP connections.
k6 (like most HTTP clients) reuses keep-alive connections, and connection tracking
keeps sending each one to the same pod. During preStop, requests on those
connections keep arriving at the terminating pod. After SIGTERM they hang, and
SIGKILL ends them with EOF. preStop can't fix this alone, because the server has to
stop accepting requests on existing connections (e.g. reply `Connection: close`),
and llama-server doesn't.

**Verification.** See the README results: the same test with k6
`noConnectionReuse` (one connection per request).

**Production options.**
- Put a proxy that drains properly in front of the model server (Envoy sidecar,
  or a gateway / service mesh that closes upstream connections on endpoint removal).
- Route clients through the GKE Gateway. The Google L7 LB holds the client
  connections and drains backends itself (`GCPBackendPolicy.connectionDraining`).
- Client side: a bounded idle timeout / max requests per connection.
