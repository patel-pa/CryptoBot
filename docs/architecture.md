# Architecture

CryptoBot v2 runs on **Amazon EKS** in `eu-central-1` (Frankfurt; Binance refuses US addresses).
Two environments, `dev` and `prod`, share one cluster as two Kubernetes namespaces; each has its
own Amazon RDS for PostgreSQL and Amazon DocumentDB. Terraform builds the AWS infrastructure (the
load balancers come from the Load Balancer Controller that Terraform installs), and GitHub Actions
builds, tests, scans and deploys the one application image.

Four views, from the inside out:

1. [Application components](#1-application-components): what the program does with the data
2. [CI/CD pipeline](#2-cicd-pipeline): how a change gets from `git push` to dev and prod
3. [AWS infrastructure](#3-aws-infrastructure): the network, the cluster, the databases, the Terraform layers
4. [Kubernetes architecture](#4-kubernetes-architecture): the objects inside the cluster

---

## 1. Application components

```mermaid
flowchart LR
    subgraph binance["Binance (internet)"]
        rest["REST API<br/>closed 1-minute candles"]
        ws["WebSocket<br/>live ticks and candles"]
    end

    subgraph app["CryptoBot pods"]
        ingest["ingest<br/>CronJob, every 15 min"]
        retrain["retrain<br/>CronJob, daily 03:00 UTC"]
        streamer["streamer<br/>Deployment, 1 pod"]
        api["API, FastAPI<br/>Deployment"]
        dash["dashboard, Streamlit<br/>Deployment"]
    end

    pg[("Amazon RDS<br/>PostgreSQL<br/>candle history")]
    mongo[("Amazon DocumentDB<br/>closed candles<br/>and forecasts")]
    s3[("Amazon S3<br/>model.pkl, versioned")]
    user(["Browser"])

    rest --> ingest --> pg
    rest --> retrain
    pg --> retrain -- "upload new version" --> s3
    ws --> streamer -- "save closed candle" --> mongo
    streamer -- "POST /predict" --> api
    s3 -- "download, cache,<br/>pick up newer version" --> api
    mongo -- "latest candle" --> api
    api -- "store forecast" --> mongo
    pg -- "history" --> api
    ws -- "relayed by /stream" --> api
    user -- "HTTP through the ALB" --> dash
    dash -- "/charts, /predictions, /stream" --> api
```

One candle's journey: a 1-minute candle closes on Binance → the **streamer** receives it over the
WebSocket and saves it in **DocumentDB** → it calls **`POST /predict`** → the **API** predicts the next
close with the model it cached from **S3** and stores the forecast in DocumentDB → the **dashboard**
shows history (PostgreSQL), the live price, the forecast and forecast-vs-actual. Every 15 minutes
**ingest** tops up PostgreSQL from the REST API; once a day **retrain** does the same, trains a new
model on the history and uploads it as a new S3 version, which the API loads by itself.

| Process | Kubernetes object | Reads | Writes |
|---|---|---|---|
| `python -m src.cli ingest` | CronJob `ingest` (`*/15 * * * *`) | Binance REST | PostgreSQL (insert, existing rows skipped; only closed candles) |
| `python -m src.cli retrain` | CronJob `retrain` (`0 3 * * *`) | Binance REST, PostgreSQL | PostgreSQL, S3 `<env>/model.pkl` |
| `python -m src.collection.stream_live` | Deployment `streamer` (exactly 1 pod) | Binance WebSocket | DocumentDB; calls `POST /predict` |
| `uvicorn src.api.main:app` | Deployment `api` (dev 1, prod 2 pods) | PostgreSQL, DocumentDB, S3, Binance WebSocket (relayed by `/stream`) | DocumentDB (forecasts) |
| Streamlit `src/visualization/app.py` | Deployment `dashboard` | the API only | – |
| `python -m src.storage.init_db` | Job `init-db` (every deploy) | – | tables in PostgreSQL, unique indexes in DocumentDB for candles and forecasts (idempotent) |

Every process is stateless: data lives in the two databases and S3, so pods and even the whole
cluster can be replaced at any time.

---

## 2. CI/CD pipeline

```mermaid
flowchart LR
    push["git push to dev"]
    ci["CI: ci.yml + terraform.yml<br/>manifests rendered + kubeconform,<br/>Trivy config scan,<br/>Terraform fmt / validate / tests,<br/>actionlint, zizmor<br/>other branches also: ruff, pytest,<br/>image build + Trivy"]
    image["CD: Test, build, scan, push<br/>ruff, pytest, docker build,<br/>Trivy stops on CRITICAL"]
    ecr[("Amazon ECR<br/>tag = commit SHA,<br/>immutable")]
    deploydev["CD: Deploy to dev<br/>kubectl apply -k overlays/dev,<br/>wait for init-db and rollouts"]
    pr["Pull request dev to main<br/>4 required checks green"]
    merge["merge commit on main"]
    approve{"approval in GitHub<br/>environment production"}
    deployprod["CD: Deploy to prod<br/>same files as the tested dev commit?<br/>extra tag prod-SHA, deploy by digest"]
    manual_dev["manual run on dev<br/>gh workflow run cd.yml<br/>optional image_sha"]
    manual_main["manual run on main<br/>gh workflow run cd.yml<br/>optional image_sha"]

    push --> ci
    push --> image -- "OIDC sign-in, no stored keys" --> ecr
    image --> deploydev
    ecr --> deploydev
    deploydev --> devns["namespace dev"]
    pr --> merge --> approve --> deployprod
    ecr --> deployprod
    deployprod --> prodns["namespace prod"]
    manual_dev -. "deploy or roll back" .-> deploydev
    manual_main -. "deploy or roll back" .-> approve
```

- **Branches:** work happens on `dev`; `main` is the stable branch and changes only through a pull
  request whose four required checks are green, merged as a merge commit (GitHub rulesets, nobody
  may bypass them).
- **Build once, promote the same image:** only a push to `dev` builds an image. Prod gets exactly
  that image, by digest, after the prod job has checked that `main` holds exactly the tested dev
  commit's files. Nothing is rebuilt for prod.
- **Approval gate:** the prod job runs in the GitHub environment `production`, which waits for the
  owner's approval and allows only `main`.
- **No stored cloud keys:** only the three CD jobs touch AWS (CI and the Terraform checks never do);
  each signs in with short-lived OIDC credentials under its own IAM role, and each deploy role may
  change only its own namespace.
- **Rollback:** a manual run with an older commit SHA deploys that commit's manifests and image
  again (prod: an older merge on `main`, again with approval). See
  [disaster-recovery.md](disaster-recovery.md#4-roll-back-to-a-previous-version).

---

## 3. AWS infrastructure

```mermaid
flowchart TB
    internet(["Internet: users, Binance, GitHub Actions"])

    subgraph aws["AWS eu-central-1"]
        subgraph boot["bootstrap layer, kept"]
            state[("S3: Terraform state")]
            oidc["GitHub OIDC provider<br/>3 CI roles"]
            ecr[("ECR repository")]
            models[("S3: model bucket<br/>versioned")]
            logs[("CloudWatch log groups<br/>7 days")]
        end

        eks["EKS control plane<br/>Kubernetes 1.37, run by AWS"]
        sm["Secrets Manager<br/>cryptobot/dev/…<br/>cryptobot/prod/…"]

        subgraph vpc["platform layer: VPC"]
            subgraph pub["public subnets, 2 zones"]
                nat["NAT gateway"]
                alb["ALBs cryptobot-dev,<br/>cryptobot-prod"]
            end
            subgraph priv["private subnets, 2 zones"]
                nodes["managed node group<br/>3 × t3.medium"]
                rds[("RDS PostgreSQL<br/>dev, prod")]
                docdb[("DocumentDB<br/>dev, prod")]
            end
            s3ep["S3 gateway endpoint"]
        end
    end

    internet --> alb --> nodes
    nodes --> nat --> internet
    internet -- "kubectl from CD" --> eks
    eks --- nodes
    nodes -- "TLS, only from the nodes" --> rds
    nodes -- "TLS, only from the nodes" --> docdb
    nodes --> s3ep --> models
    s3ep -- "image layers" --> ecr
    nodes -. "External Secrets" .-> sm
    nodes -. "Fluent Bit" .-> logs
```

| Terraform layer | Lifetime | What it creates |
|---|---|---|
| `infra/terraform/bootstrap` | created once, **kept** | state bucket, GitHub OIDC + CI roles, ECR, the versioned model bucket, CloudWatch log groups |
| `infra/terraform/platform` | created and **destroyed every work session** | VPC (2 zones, 1 NAT gateway, S3 endpoint), EKS + 3 nodes, add-ons (VPC CNI, CoreDNS, kube-proxy, Pod Identity agent, CloudWatch container logs), AWS Load Balancer Controller, External Secrets, monitoring (kube-prometheus-stack), namespaces, deploy permissions |
| `infra/terraform/envs/dev` | every session | RDS + DocumentDB (smallest, 1-day backups, no deletion protection), 4 secrets, SecretStore, pod roles |
| `infra/terraform/envs/prod` | every session; **final snapshot on destroy, restore on create** | the same with prod values (7-day backups, deletion protection) |

`envs/dev` and `envs/prod` call the same module (`infra/terraform/modules/environment`) with
different values. The databases sit in private subnets; their security groups accept only the
nodes. Passwords are generated by Terraform as write-only values and stored only in Secrets
Manager, never in the Terraform state. The ALBs are not in Terraform: the Load Balancer Controller
creates them from each environment's Ingress, so the teardown deletes the Ingresses first.

---

## 4. Kubernetes architecture

```mermaid
flowchart TB
    alb_prod["ALB cryptobot-prod"]
    alb_dev["ALB cryptobot-dev"]

    subgraph cluster["EKS cluster, 3 nodes"]
        subgraph prod["namespace prod"]
            p_ing["Ingress dashboard"]
            p_dash["Deployment + Service dashboard"]
            p_api["Deployment api, 2 pods<br/>Service api, PodDisruptionBudget"]
            p_str["Deployment streamer, 1 pod"]
            p_jobs["CronJobs ingest, retrain<br/>Job init-db"]
            p_cfg["ConfigMap cryptobot-config<br/>Secrets from ExternalSecrets"]
        end
        subgraph dev["namespace dev"]
            d_all["the same objects<br/>as prod, 1 API pod,<br/>no PodDisruptionBudget"]
        end
        subgraph mon["namespace monitoring"]
            prom["Prometheus"]
            graf["Grafana<br/>dashboards and alert"]
            ksm["kube-state-metrics"]
            ne["node-exporter, per node"]
        end
        subgraph sys["system namespaces"]
            lbc["AWS Load Balancer Controller"]
            eso["External Secrets Operator"]
            fb["Fluent Bit, per node"]
        end
    end

    alb_prod --> p_ing --> p_dash --> p_api
    alb_dev --> d_all
    p_str -- "POST /predict" --> p_api
    lbc -. "creates from the Ingress" .-> alb_prod
    eso -. "SecretStore owned by Terraform" .-> p_cfg
    prom -- "scrapes /metrics" --> p_api
    prom --> ksm
    prom --> ne
    graf -- "PromQL" --> prom
```

| Object | Settings that matter |
|---|---|
| Deployment `api` | liveness probe `/health` (the process answers; restart if not) and readiness probe `/ready` (both databases answer; no traffic if not); requests and memory limits; prod: 2 pods spread over the nodes, PodDisruptionBudget `minAvailable: 1` |
| Deployment `dashboard` | liveness and readiness probe on Streamlit's `/_stcore/health` |
| Deployment `streamer` | exactly 1 pod, strategy `Recreate` (a second pod would only repeat each candle write and forecast request: wasted work; the upserts keep one copy) |
| CronJobs `ingest`, `retrain` | `concurrencyPolicy: Forbid` (never two runs at once), history 3 successful + 3 failed; a start missed by more than 5 min (`ingest`) or 1 h (`retrain`) is skipped |
| Job `init-db` | applied by every deploy, idempotent; CD waits for it to finish, then for the rollouts |
| ServiceAccounts `api`, `retrain` | EKS Pod Identity: one IAM role each (read the model / write the model); the other app pods (ServiceAccount `cryptobot`) get no AWS rights. The platform's controllers (Load Balancer Controller, External Secrets, the CloudWatch add-on's Fluent Bit) have their own roles (`infra/terraform/platform/controllers.tf`) |
| ExternalSecrets | turn `cryptobot/<env>/*` from Secrets Manager into Kubernetes Secrets through the namespace's SecretStore (created by Terraform; dev's store can never read prod's secrets) |
| Every app pod | runs as a non-root user, read-only root file system, no privilege escalation, all capabilities dropped; the namespaces `dev` and `prod` enforce Pod Security `restricted`, so Kubernetes refuses any pod that may run as root, gain privileges, keep capabilities or reach into the node (the read-only root file system is our own setting, not enforced) |
| Monitoring | kube-prometheus-stack (Helm, installed by Terraform): a ServiceMonitor scrapes the API in `dev` and `prod`; Grafana loads the dashboards and the alert rule from `monitoring/` (details in [monitoring/README.md](../monitoring/README.md)) |
| Logs | Fluent Bit (EKS CloudWatch add-on) sends every container's output to CloudWatch Logs |
| Local copy | `k8s/overlays/local` runs the same base on kind, with PostgreSQL and MongoDB as pods |
