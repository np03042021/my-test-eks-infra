# Rendered by scripts/up.sh (__APP_REPO__ is replaced with $APP_REPO).
---
# Dedicated project instead of "default": this app may only deploy from the app repo,
# only into spr-app, and the only cluster-scoped kind it may create is its Namespace.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: spr
  namespace: argocd
spec:
  description: Secure paved road demo app
  sourceRepos:
    - __APP_REPO__
  destinations:
    - server: https://kubernetes.default.svc
      namespace: spr-app
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spr-app
  namespace: argocd
  # Cascade delete: removing the Application deletes its resources, including the Ingress,
  # so the AWS Load Balancer Controller deletes the ALB before the VPC is destroyed.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: spr
  source:
    repoURL: __APP_REPO__
    targetRevision: main
    path: charts/app
  destination:
    server: https://kubernetes.default.svc
    namespace: spr-app
  syncPolicy:
    automated:
      prune: true    # resources removed from Git are removed from the cluster
      selfHeal: true # manual kubectl drift is reverted to what Git says
