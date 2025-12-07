# Homelab

Production-grade Kubernetes on Hetzner Cloud.

## Live

**[etcd.me](https://etcd.me)** | [Portfolio](https://sofianedjerbi.com)

## Stack

- **Talos Linux** - Immutable Kubernetes OS
- **Terragrunt** - Infrastructure as Code
- **ArgoCD** - GitOps deployments
- **SOPS + age** - Secret encryption
- **Cilium** - CNI with Gateway API
- **Cloudflare** - DNS and SSL

## Structure

```
terraform/
  modules/        # Reusable infra (cluster, dns, firewall)
  live/           # Per-cluster stacks
argocd/
  base/           # Shared manifests
  overlays/       # Per-cluster config
tasks/            # Automation
```

## Bootstrap

```bash
task tg -- stack run apply terraform/live/etcdme-nbg1-dc3
task argocd:bootstrap
```

## Services

Postgres, Keycloak, Grafana, Uptime Kuma, n8n, and more.

---

Built by [Sofiane Djerbi](https://sofianedjerbi.com)
