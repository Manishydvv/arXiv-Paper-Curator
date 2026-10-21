# Complete EKS Deployment Guide (PowerShell Edition)

This guide walks you through deploying the entire arXiv Paper Curator platform onto AWS Elastic Kubernetes Service (EKS).

## 1. Prerequisites
Ensure you have the following installed on your Windows machine:
* AWS CLI v2
* Docker Desktop (running)
* `kubectl`
* `eksctl`

Run `aws configure` to log into your AWS account.

## 2. Set Environment Variables
Open PowerShell and run:
```powershell
$env:AWS_REGION="us-east-1"
$env:CLUSTER_NAME="agentic-rag-cluster"
$env:ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$env:AWS_REGION.amazonaws.com"
$env:K8S_NAMESPACE="production"
```

## 3. Create ECR Repositories & Push Images
```powershell
# Create repositories
aws ecr create-repository --repository-name agentic-rag/api --region $env:AWS_REGION
aws ecr create-repository --repository-name agentic-rag/airflow --region $env:AWS_REGION

# Login to ECR
aws ecr get-login-password --region $env:AWS_REGION | docker login --username AWS --password-stdin $env:ECR_REGISTRY

# Build API Image
docker buildx build --platform linux/amd64 -t $env:ECR_REGISTRY/agentic-rag/api:manual --load .
docker push $env:ECR_REGISTRY/agentic-rag/api:manual

# Build Airflow Image
docker buildx build --platform linux/amd64 -f airflow/Dockerfile -t $env:ECR_REGISTRY/agentic-rag/airflow:manual --load .
docker push $env:ECR_REGISTRY/agentic-rag/airflow:manual
```

## 4. Create the EKS Cluster
```powershell
eksctl create cluster --name $env:CLUSTER_NAME --region $env:AWS_REGION --version 1.31 --nodegroup-name rag-workers --node-type t3.large --nodes 2 --nodes-min 1 --nodes-max 3 --managed
```
*(This process takes 15-20 minutes)*

## 5. IAM & Secrets Setup
```powershell
# Create production namespace
kubectl create namespace $env:K8S_NAMESPACE

# Push your local .env to Kubernetes
kubectl create secret generic rag-app-secrets --from-env-file=".env" --namespace $env:K8S_NAMESPACE
```

## 6. Install EBS CSI Driver (For OpenSearch Database)
```powershell
$NODE_ROLE_ARN = (aws eks describe-nodegroup --cluster-name $env:CLUSTER_NAME --nodegroup-name rag-workers --region $env:AWS_REGION --query "nodegroup.nodeRole" --output text)
$NODE_ROLE_NAME = $NODE_ROLE_ARN -replace '^.*/', ''
aws iam attach-role-policy --role-name $NODE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

eksctl create addon --name aws-ebs-csi-driver --cluster $env:CLUSTER_NAME --region $env:AWS_REGION --force

# Create GP3 Storage Class
$sc = @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
"@
$sc | Out-File -FilePath "$env:TEMP\gp3-sc.yaml" -Encoding ascii
kubectl apply -f "$env:TEMP\gp3-sc.yaml"
```

## 7. Deploy Applications
```powershell
# OpenSearch
kubectl apply -f deployment/k8s/opensearch/statefulset.yaml
kubectl apply -f deployment/k8s/opensearch/service.yaml

# RAG API
kubectl apply -f deployment/k8s/api/deployment.yaml
kubectl apply -f deployment/k8s/api/service.yaml

# Airflow
kubectl create configmap airflow-dags --from-file="airflow/dags/" --namespace $env:K8S_NAMESPACE
kubectl apply -f deployment/k8s/airflow/deployment.yaml
kubectl apply -f deployment/k8s/airflow/service.yaml
```

## 8. Verification
```powershell
# Get LoadBalancer Links
kubectl get services -n $env:K8S_NAMESPACE

# View live logs
kubectl logs -n $env:K8S_NAMESPACE -l app=rag-api -f
```

## 9. Cleanup & Teardown
```powershell
eksctl delete cluster --name $env:CLUSTER_NAME --region $env:AWS_REGION
```
