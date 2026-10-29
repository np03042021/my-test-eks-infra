############################################
# Cluster controllers via Helm. Single replicas to fit 2 small Spot nodes.
# DEMO ONLY: prod runs >= 2 replicas with PodDisruptionBudgets.
# Check chart versions: helm repo update && helm search repo <repo>/<chart>
############################################

# AWS Load Balancer Controller: turns Ingress objects into ALBs. Cost: $0 itself; each ALB ~$0.54/day + LCUs.
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    # Set explicitly: with IMDS hop limit 1 the controller cannot discover region/VPC from instance metadata.
    region       = var.region
    vpcId        = module.vpc.vpc_id
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller" # must match the Pod Identity association
    }
    # We only use Ingress. Disabling the Service mutating webhook (failurePolicy: Fail) avoids
    # blocking every Service creation in the cluster whenever this single replica is down.
    enableServiceMutatorWebhook = false
  })]

  depends_on = [module.eks, module.lbc_pod_identity]
}

# External Secrets Operator: syncs Secrets Manager -> Kubernetes Secret. Cost: $0 (+$0.40/month per secret).
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    installCRDs  = true
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "external-secrets" # must match aws_eks_pod_identity_association.eso
    }
    webhook        = { replicaCount = 1 }
    certController = { replicaCount = 1 }
  })]

  depends_on = [helm_release.aws_lbc, aws_eks_pod_identity_association.eso]
}

# Argo CD: GitOps pull model, so CI never holds cluster credentials. Cost: $0.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.6"
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    # DEMO ONLY: no SSO (dex) - log in with the initial admin password. Prod: OIDC SSO, disable local admin.
    dex           = { enabled = false }
    notifications = { enabled = false }
    # ClusterIP only, reached via kubectl port-forward: no second load balancer, no internet exposure.
    server = {
      service = { type = "ClusterIP" }
    }
  })]

  depends_on = [helm_release.aws_lbc]
}
