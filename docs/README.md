# DevOps Case Study — MERN Stack + Python ETL Deployment

## İçindekiler

1. [Mimari Genel Bakış](#mimari-genel-bakış)
2. [Klasör Yapısı](#klasör-yapısı)
3. [Gereksinimler](#gereksinimler)
4. [Adım Adım Kurulum](#adım-adım-kurulum)
   - [1. AWS Altyapısı (Terraform)](#1-aws-altyapısı-terraform)
   - [2. Docker Image'larını Build Etme](#2-docker-imagelarını-build-etme)
   - [3. Kubernetes'e Deploy](#3-kubernetese-deploy)
   - [4. CI/CD Pipeline Kurulumu](#4-cicd-pipeline-kurulumu)
   - [5. Monitoring & Alerting](#5-monitoring--alerting)
5. [Local Development](#local-development)
6. [Güvenlik Notları](#güvenlik-notları)
7. [Karşılaşılan Zorluklar](#karşılaşılan-zorluklar)

---

## Mimari Genel Bakış

```
                        ┌─────────────────────────────────────────────┐
                        │              AWS Cloud (eu-west-1)           │
                        │                                              │
  Internet              │    ┌──────────────┐                         │
  ──────────► Route 53 ──────►  ALB Ingress  │                        │
                        │    └──────┬───────┘                         │
                        │           │                                  │
                        │    ┌──────▼──────────────────────────────┐  │
                        │    │          EKS Cluster                 │  │
                        │    │                                      │  │
                        │    │  ┌──────────┐    ┌───────────────┐  │  │
                        │    │  │  React   │    │  Express API  │  │  │
                        │    │  │  Client  │    │  (2 replicas) │  │  │
                        │    │  │ (2 reps) │    │  Port: 5050   │  │  │
                        │    │  └──────────┘    └───────┬───────┘  │  │
                        │    │                          │           │  │
                        │    │  ┌───────────────────────▼───────┐  │  │
                        │    │  │     MongoDB StatefulSet        │  │  │
                        │    │  │     (EBS gp3, 10Gi)            │  │  │
                        │    │  └───────────────────────────────┘  │  │
                        │    │                                      │  │
                        │    │  ┌───────────────────────────────┐  │  │
                        │    │  │  Python ETL CronJob (1h/kez)  │  │  │
                        │    │  └───────────────────────────────┘  │  │
                        │    └──────────────────────────────────────┘  │
                        │                                              │
                        │    ┌──────┐  ┌──────────┐  ┌───────────┐   │
                        │    │ ECR  │  │CloudWatch│  │  Secrets  │   │
                        │    │(3    │  │  Logs    │  │  Manager  │   │
                        │    │repos)│  └──────────┘  └───────────┘   │
                        │    └──────┘                                 │
                        └─────────────────────────────────────────────┘

CI/CD (GitHub Actions):
  Push → Test → Build & Push ECR → Deploy EKS → Slack Notify
```

**Teknoloji Seçimleri:**

| Bileşen | Teknoloji | Gerekçe |
|---|---|---|
| Cloud | AWS | Geniş ekosistem, EKS managed K8s, ECR entegrasyonu |
| Container Orchestration | Kubernetes (EKS) | Production-grade, autoscaling, rolling updates |
| IaC | Terraform | Deklaratif, state yönetimi, modüler yapı |
| CI/CD | GitHub Actions | Repo ile entegre, YAML-tabanlı, ücretsiz tier |
| Monitoring | Prometheus + Alertmanager | K8s native, zengin alert kuralları |
| Logging | CloudWatch Logs | AWS native, EKS container log aggregation |
| Container Registry | AWS ECR | AWS entegrasyonu, güvenlik taraması |

---

## Klasör Yapısı

```
devops-solution/
├── dockerfiles/
│   ├── Dockerfile.server    # Node.js Express backend (multi-stage)
│   ├── Dockerfile.client    # React frontend (multi-stage + nginx)
│   ├── Dockerfile.etl       # Python ETL
│   ├── nginx.conf           # Nginx reverse proxy config
│   └── requirements.txt     # Python dependencies
├── kubernetes/
│   ├── mern/
│   │   ├── 00-namespace.yaml    # Namespace + ConfigMap
│   │   ├── 01-secrets.yaml      # Kubernetes Secrets (şablonu)
│   │   ├── 02-mongodb.yaml      # MongoDB StatefulSet + Service
│   │   ├── 03-server.yaml       # Express Deployment + HPA
│   │   └── 04-client.yaml       # React Deployment + Ingress
│   ├── python-etl/
│   │   └── cronjob.yaml         # Python ETL CronJob (saatlik)
│   └── monitoring/
│       └── alerts.yaml          # Prometheus Rules + Alertmanager
├── ci-cd/
│   └── github-actions/
│       ├── mern-cicd.yml        # MERN CI/CD pipeline
│       └── etl-cicd.yml         # Python ETL CI/CD pipeline
├── terraform/
│   ├── main.tf                  # VPC, EKS, ECR
│   └── variables.tf
├── docker-compose.yml           # Local development
└── README.md                    # Bu dosya
```

---

## Gereksinimler

- AWS CLI v2 (`aws configure` ile yapılandırılmış)
- Terraform >= 1.5
- kubectl >= 1.28
- Docker >= 24.0
- Helm >= 3.12
- GitHub hesabı (Actions için)

---

## Adım Adım Kurulum

### 1. AWS Altyapısı (Terraform)

```bash
cd terraform/

# Terraform backend için S3 bucket oluştur (bir kez)
aws s3 mb s3://mern-terraform-state --region eu-west-1
aws dynamodb create-table \
  --table-name mern-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1

# Terraform init & deploy
terraform init
terraform plan -var="aws_region=eu-west-1" -var="environment=production"
terraform apply -auto-approve
```

Terraform şunları oluşturur:
- VPC (3 public + 3 private subnet, NAT Gateway)
- EKS Cluster (v1.28, t3.medium node group, 2-4 node autoscaling)
- ECR Repositories (mern-server, mern-client, python-etl)
- CloudWatch Log Group

### 2. Docker Image'larını Build Etme

```bash
# AWS Kimlik Bilgilerini al
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=eu-west-1

# ECR'ye giriş yap
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Server image
docker build -t mern-server -f dockerfiles/Dockerfile.server .
docker tag mern-server $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mern-server:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mern-server:latest

# Client image
docker build -t mern-client \
  -f dockerfiles/Dockerfile.client \
  --build-arg REACT_APP_SERVER_URL=https://mern-app.yourdomain.com/api \
  .
docker tag mern-client $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mern-client:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mern-client:latest

# Python ETL image
docker build -t python-etl -f dockerfiles/Dockerfile.etl .
docker tag python-etl $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/python-etl:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/python-etl:latest
```

### 3. Kubernetes'e Deploy

```bash
# kubeconfig güncelle
aws eks update-kubeconfig --region eu-west-1 --name mern-devops-case-eks-cluster

# Image URL'lerini gerçek değerlerle replace et
sed -i "s/YOUR_AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID/g" kubernetes/mern/*.yaml
sed -i "s/YOUR_REGION/$AWS_REGION/g" kubernetes/mern/*.yaml kubernetes/python-etl/*.yaml

# Namespace & ConfigMap
kubectl apply -f kubernetes/mern/00-namespace.yaml

# Secret'ları güvenli şekilde oluştur (dosyayı ASLA commit etme)
kubectl create secret generic mern-secrets \
  --from-literal=ATLAS_URI="mongodb://admin:SIFRENIZ@mern-mongodb-service:27017/sample_training?authSource=admin" \
  --from-literal=MONGO_USERNAME="admin" \
  --from-literal=MONGO_PASSWORD="SIFRENIZ" \
  -n mern-app

# Sırayla deploy et
kubectl apply -f kubernetes/mern/02-mongodb.yaml
kubectl wait --for=condition=ready pod -l app=mongodb -n mern-app --timeout=120s

kubectl apply -f kubernetes/mern/03-server.yaml
kubectl wait --for=condition=ready pod -l app=mern-server -n mern-app --timeout=120s

kubectl apply -f kubernetes/mern/04-client.yaml
kubectl apply -f kubernetes/python-etl/cronjob.yaml

# Durumu kontrol et
kubectl get all -n mern-app
```

**Beklenen çıktı:**
```
NAME                               READY   STATUS    RESTARTS   AGE
pod/mern-mongodb-0                 1/1     Running   0          5m
pod/mern-server-7d9f8b9c4-abc12    1/1     Running   0          3m
pod/mern-server-7d9f8b9c4-def34    1/1     Running   0          3m
pod/mern-client-6c8f7d4b5-ghi56    1/1     Running   0          2m
pod/mern-client-6c8f7d4b5-jkl78    1/1     Running   0          2m

NAME                          TYPE        CLUSTER-IP      PORT(S)
service/mern-mongodb-service  ClusterIP   None            27017/TCP
service/mern-server-service   ClusterIP   10.100.10.1     5050/TCP
service/mern-client-service   ClusterIP   10.100.10.2     80/TCP

NAME                          CLASS   HOSTS                    ADDRESS
ingress/mern-ingress          alb     mern-app.yourdomain.com  <ALB_DNS>

CRONJOB:
python-etl-cronjob   0 * * * *   False   0   <none>   1m
```

### 4. CI/CD Pipeline Kurulumu

GitHub repository'nizde şu **Secrets** tanımlayın:

```
Settings → Secrets and variables → Actions → New repository secret

AWS_ACCESS_KEY_ID          = <IAM user access key>
AWS_SECRET_ACCESS_KEY      = <IAM user secret key>
AWS_ACCOUNT_ID             = <12-digit AWS account ID>
REACT_APP_SERVER_URL       = https://mern-app.yourdomain.com/api
SLACK_WEBHOOK_URL          = https://hooks.slack.com/services/...
```

Workflow tetikleyicileri:
- `main` branch'e push → Test + Build + Deploy (production)
- `develop` branch'e push → Test + Build (staging)
- PR açılması → yalnızca Test

ETL pipeline yalnızca `python-project/` klasörü değiştiğinde tetiklenir.

### 5. Monitoring & Alerting

**Prometheus Stack kurulumu:**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.enabled=true \
  --set alertmanager.enabled=true

# Alert kurallarını uygula
kubectl apply -f kubernetes/monitoring/alerts.yaml
```

**Aktif Alert Kuralları:**

| Alert | Koşul | Önem |
|---|---|---|
| MernPodCrashLooping | Pod 2dk+ süre restart ediyor | Critical |
| MernServerHighErrorRate | 5xx oranı > %5 | Warning |
| MernPodNotReady | Pod 5dk+ NotReady | Critical |
| EtlCronJobFailed | ETL job başarısız | Warning |
| MernHighCPU | CPU limiti > %80 | Warning |
| MernHighMemory | Memory limiti > %85 | Warning |

**CloudWatch Log izleme:**
```bash
# EKS container loglarını görüntüle
aws logs tail /aws/eks/mern-devops-case-eks-cluster/cluster --follow

# Belirli pod logları
kubectl logs -l app=mern-server -n mern-app --tail=100 -f
kubectl logs -l app=python-etl -n mern-app --tail=50
```

---

## Local Development

```bash
# .env dosyasını oluştur
cat > .env << EOF
MONGO_USERNAME=admin
MONGO_PASSWORD=localpassword
EOF

# Tüm servisleri başlat
docker compose up --build

# Erişim:
# Frontend: http://localhost:3000
# Backend API: http://localhost:5050
# Healthcheck: http://localhost:5050/healthcheck
# MongoDB: mongodb://admin:localpassword@localhost:27017

# ETL'i bir kez çalıştır (test)
docker compose run --rm etl
```

---

## Güvenlik Notları

1. **Secret yönetimi:** Kubernetes Secrets base64 encoded'dır (encrypted at rest değildir). Production'da AWS Secrets Manager + External Secrets Operator kullanılması önerilir.

2. **Non-root containers:** Tüm Dockerfile'lar non-root user ile çalışmaktadır.

3. **Network isolation:** MongoDB ve backend, ClusterIP (sadece cluster-içi erişim) servisleri üzerindedir. Dışarıdan direkt erişim yoktur.

4. **Resource limits:** Tüm container'lara CPU/Memory request ve limit tanımlanmıştır; "noisy neighbor" problemini önler.

5. **ECR image scanning:** `scan_on_push = true` ile her push'ta vulnerability taraması çalışır.

6. **HTTPS:** Ingress SSL redirect ile HTTP → HTTPS zorunlu kılınmıştır.

---

## Karşılaşılan Zorluklar

### 1. MongoDB bağlantı dizisi (conn.mjs)
Orijinal kodda `loadEnvironment.mjs` `dotenv`'i `./config.env` dosyasından okuyordu. Container ortamında bu path çalışmadığı için environment variable (`ATLAS_URI`) üzerinden sağlanan bağlantı dizisi kullanıldı. Kubernetes Secret'ından `ATLAS_URI` env var olarak inject edildi.

### 2. React build-time environment variable
React'ta `REACT_APP_*` değişkenleri build sırasında bundle'a gömülür. Bu nedenle backend URL'i Docker build arg olarak geçildi ve CI/CD pipeline'da `REACT_APP_SERVER_URL` secret olarak tanımlandı.

### 3. MongoDB persistent storage
StatefulSet + PersistentVolumeClaim ile AWS EBS gp3 volume kullanıldı. Headless service ile pod DNS adreslenebilirliği sağlandı (`mern-mongodb-0.mern-mongodb-service.mern-app.svc.cluster.local`).

### 4. Python ETL — saatlik çalışma
Python projesi tek bir script içeriyor. Kubernetes CronJob (schedule: `0 * * * *`) ile her saat başı tetikleniyor. `concurrencyPolicy: Forbid` ile eş zamanlı çalışma engellendi, `backoffLimit: 2` ile hata durumunda retry mekanizması eklendi.
