# ingress2gateway-kind-demo

A local end-to-end demo of the [ingress2gateway 1.0](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/) migration tool running on [kind](https://kind.sigs.k8s.io/).

It walks through the complete journey from a classic `Ingress` with NGINX annotations all the way to `Gateway` + `HTTPRoute` resources managed by **Envoy Gateway**.

---

## What this demo shows

| Stage | Resource | File |
|-------|----------|------|
| **Before** | `Ingress` with `nginx.ingress.kubernetes.io/*` annotations | `ingress/demo-ingress.yaml` |
| **Tool** | `ingress2gateway print` translates the Ingress to Gateway API YAML | `scripts/demo-migration.sh` |
| **After** | `GatewayClass`, `Gateway`, `HTTPRoute` | `gateway/gateway.yaml`, `gateway/httproute.yaml` |

Key annotations demonstrated:

- `nginx.ingress.kubernetes.io/rewrite-target` → `HTTPRoute` `URLRewrite` filter  
- `nginx.ingress.kubernetes.io/enable-cors` + `cors-allow-origin` → (tool flags as implementation-specific)  
- `nginx.ingress.kubernetes.io/backend-protocol` → backend `port` mapping  

ingress2gateway 1.0 supports **30+ Ingress-NGINX annotations**, each backed by live integration tests verifying behavioral equivalence.

---

## Project layout

```
ingress2gateway-kind-demo/
├── kind-config.yaml              # kind cluster definition (ports 8080/8443)
├── apps/
│   ├── nginx-demo/
│   │   └── deployment.yaml       # nginx:alpine Deployment + Service
│   └── echo-demo/
│       └── deployment.yaml       # echo-server Deployment + Service
├── ingress/
│   └── demo-ingress.yaml         # Classic Ingress (the BEFORE state)
├── gateway/
│   ├── gateway.yaml              # GatewayClass + Gateway
│   └── httproute.yaml            # HTTPRoute (the AFTER state)
└── scripts/
    ├── setup.sh                  # Bootstrap cluster, install deps, deploy apps
    ├── demo-migration.sh         # Run ingress2gateway and cut over
    ├── test.sh                   # Port-forward and curl endpoints
    └── teardown.sh               # Delete the kind cluster
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [Docker](https://docs.docker.com/get-docker/) | 24+ | Required by kind |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | v0.23+ | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.29+ | `brew install kubectl` |
| [Helm](https://helm.sh/docs/intro/install/) | v3.14+ | `brew install helm` |
| [Go](https://go.dev/dl/) | 1.21+ | Required to install ingress2gateway |
| [curl](https://curl.se/) | any | Pre-installed on most systems |

---

## Quick start

```bash
# Clone the repo
git clone https://github.com/your-org/ingress2gateway-kind-demo.git
cd ingress2gateway-kind-demo

# 1. Bootstrap the cluster, install Gateway API CRDs & Envoy Gateway, deploy apps
./scripts/setup.sh

# 2. Run the migration demo (applies classic Ingress, runs ingress2gateway, cuts over)
./scripts/demo-migration.sh

# 3. Test that the Gateway API routes work
./scripts/test.sh

# 4. When done, tear everything down
./scripts/teardown.sh
```

---

## Step-by-step walkthrough

### 1. Create the kind cluster

```bash
kind create cluster --config kind-config.yaml
```

The cluster exposes port **8080** (HTTP) and **8443** (HTTPS) on localhost.

### 2. Install Gateway API CRDs

```bash
kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### 3. Install Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm
  --version v1.7.1 \
  -n envoy-gateway-system\
  --create-namespace
helm repo update
```

### 4. Deploy sample apps

```bash
kubectl create namespace demo
kubectl apply -f apps/nginx-demo/deployment.yaml
kubectl apply -f apps/echo-demo/deployment.yaml
```

### 5. Apply the classic Ingress (the BEFORE state)

```bash
kubectl apply -f ingress/demo-ingress.yaml
kubectl get ingress -n demo
```

### 6. Run ingress2gateway

Install the tool:

```bash
go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0
```

Go puts binaries in $(go env GOPATH)/bin — add it to PATH if needed

```bash
export PATH="$PATH:$(go env GOPATH | sed 's|\\|/|g' | sed 's|C:|/drives/c|')/bin"
```

ingress2gateway version

```bash
ingress2gateway version v1.0.0
```

Translate your Ingress to Gateway API:

```bash
ingress2gateway print \
  --providers=ingress-nginx \
  --namespace=demo \
  --input-file=ingress/demo-ingress.yaml
```

**Read the output carefully.** The tool will:

- ✅ Translate supported annotations (rewrite-target → URLRewrite filter)
- ⚠️  Warn about annotations it cannot translate (e.g. `configuration-snippet`)
- 💡 Suggest implementation-specific alternatives where available

### 7. Review, edit, and apply the generated resources

The `gateway/` directory contains the reviewed output:

```bash
# GatewayClass + Gateway
kubectl apply -f gateway/gateway.yaml

# Wait for the Gateway to be ready
kubectl wait gateway/demo-gateway -n demo \
  --for=condition=Programmed --timeout=120s

# HTTPRoute
kubectl apply -f gateway/httproute.yaml
```

### 8. Cut over: delete the old Ingress

```bash
kubectl delete ingress demo-ingress -n demo
```

### 9. Verify

```bash
kubectl get gateway,httproute -n demo
./scripts/test.sh
```

---

## Understanding the translation

### BEFORE — Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "*"
spec:
  rules:
    - host: demo.localtest.me
      http:
        paths:
          - path: /nginx
            pathType: Prefix
            backend:
              service:
                name: nginx-demo
                port:
                  number: 80
```

### AFTER — HTTPRoute (generated by ingress2gateway, then reviewed)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-httproute
spec:
  parentRefs:
    - name: demo-gateway
  hostnames:
    - "demo.localtest.me"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /nginx
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: nginx-demo
          port: 80
```

The `rewrite-target: /` annotation maps directly to the `URLRewrite` filter. CORS annotations are flagged by the tool as implementation-specific — in Envoy Gateway you would configure these via a `BackendTrafficPolicy`.

---

## Why migrate?

- **Ingress-NGINX reached End-of-Life in March 2026.** Security vulnerabilities will no longer be patched.
- **Gateway API provides native RBAC** — infrastructure owners manage `Gateway`, app teams manage `HTTPRoute`.
- **More expressive routing** — header matching, query param routing, traffic weighting, and more are all first-class — no annotations needed.
- **Vendor-neutral** — switch implementations (Envoy Gateway, Cilium, Istio…) without rewriting your routing config.

---

## Useful commands

```bash
# Watch Gateway status
kubectl describe gateway demo-gateway -n demo

# Watch HTTPRoute status
kubectl describe httproute demo-httproute -n demo

# Envoy Gateway logs
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=gateway-helm -f

# gwctl — visual view of all Gateway API resources
# (install: go install sigs.k8s.io/gateway-api/gwctl/cmd/gwctl@latest)
gwctl get gateways -n demo
gwctl get httproutes -n demo
```

---

## Resources

- [Ingress2Gateway 1.0 announcement](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/)
- [ingress2gateway on GitHub](https://github.com/kubernetes-sigs/ingress2gateway)
- [Kubernetes Gateway API docs](https://gateway-api.sigs.k8s.io/)
- [Migrating from Ingress-NGINX guide](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [Experimenting with Gateway API using kind](https://kubernetes.io/blog/2026/01/28/experimenting-gateway-api-with-kind/)

---

## License

Apache 2.0
