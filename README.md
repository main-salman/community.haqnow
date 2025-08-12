# community.haqnow

Community document platform: bulk upload, OCR + translate, search, AI Q&A, collaboration.

This repo contains:
- Terraform IaC for Exoscale (`terraform/`)
- Deploy script (`scripts/deploy.sh`) modeled after `haqnow` to bootstrap the server
- Makefile helpers for Terraform

## Prerequisites
- Terraform 1.5+
- SSH key at `~/.ssh/id_rsa.pub` (used by Exoscale SSH key resource)
- Exoscale API credentials in `.env`

## Environment (.env)
Do NOT commit `.env`. Example keys required:
- EXOSCALE_S3_ACCESS_KEY, EXOSCALE_S3_SECRET_KEY, EXOSCALE_S3_ENDPOINT, EXOSCALE_S3_REGION
- EXOSCALE_API_KEY, EXOSCALE_SECRET_KEY
- admin_email, admin_password

## Deploy Infra
```bash
make init
make apply
make ip        # prints server IP
```

## Tighten DB Access
```bash
IP=$(terraform -chdir=terraform output -raw instance_ip)
export TF_VAR_allowed_db_cidrs="[\"${IP}/32\"]"
make apply
```

## App Deployment (non-docker)
```bash
scripts/deploy.sh           # resolves IP from Terraform output
# or
scripts/deploy.sh <SERVER_IP>
```

Notes:
- The deploy script currently uses the `haqnow` codebase as a baseline on the server to stand up backend/frontend quickly.
- Swap to your own app code by adjusting `scripts/deploy.sh` clone section.

## Architecture

```
+----------------------+           +-------------------------+
|  Developer Laptop    |           |    GitHub Repository    |
|  - README, infra     |           |  main-salman/community. |
|  - scripts/deploy.sh |  push     |  haqnow (this repo)     |
+----------+-----------+---------->+-----------+-------------+
           |                                   |
           | make/apply (Terraform)            |
           v                                   |
+----------+-----------------------------------v-------------------------+
|                         Exoscale (ch-dk-2)                              |
|                                                                         |
|  +------------------------+       +------------------------+             |
|  | Exoscale Compute VM    |       | Exoscale DBaaS         |             |
|  | (Ubuntu)               |       | - MySQL (auth/app)     |             |
|  | Public IP: 194.182...  |       | - Postgres (RAG)       |             |
|  |                        |       | ip_filter: VM /32      |             |
|  |  /opt/foi-archive      |       +------------------------+             |
|  |   ├── .env (secrets)   |                                                |
|  |   ├── site/ (static)   |        +-------------------------+            |
|  |   └── appsrc/backend   |        | Exoscale SOS (S3 API)   |            |
|  |                        |        | - Bucket: community-... |            |
|  |  Processes:            |        | - Public file URLs      |            |
|  |   - nginx :80          |        +-----------+-------------+            |
|  |     ├── /              |                    ^                          |
|  |     |    -> /var/www/community (static)     |                          |
|  |     ├── /health -> 127.0.0.1:8000/health    | s3_service (boto3)       |
|  |     └── /api/  -> 127.0.0.1:8000/           |                          |
|  |   - uvicorn community_app:app :8000         |                          |
|  |                        |                    |                          |
|  +------------------------+--------------------+--------------------------+
```

- Static site is independent and served from `/var/www/community`.
- Minimal FastAPI `community_app.py` serves `/health` while full backend deps are added incrementally.
- Secrets live only in `.env` on the VM and locally; `.gitignore` excludes them.
- Terraform defines VM, security groups, and DBaaS; DB access is narrowed to the VM `/32`.
