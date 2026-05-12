# VideoPlusSensors/preview

Reusable GitHub Action + NixOS module for ephemeral PR preview environments on a Tailscale network via Traefik.

Each pull request gets its own isolated Docker Compose stack, TLS certificate, and subdomain. Environments are deployed on open and torn down on close/merge. The server lives on your Tailscale network and is never exposed to the public internet.

## URL Pattern

```
https://{project_id}_{pr_number}.changelapse.com
```

Example: `https://vpsi_42.changelapse.com`

---

## Quick Start

### 1. Set up the server (NixOS)

Add this repo as a flake input and import the module in your NixOS configuration:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-24.11";
    preview.url     = "github:VideoPlusSensors/preview";
  };

  outputs = { nixpkgs, preview, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      modules = [
        preview.nixosModules.default
        {
          services.preview = {
            enable            = true;
            domain            = "changelapse.com";
            acmeEmail         = "ops@example.com";
            aws.accessKeyId     = "AKIA...";
            aws.secretAccessKey = "...";
            aws.hostedZoneId    = "Z1234567890ABC";
            cleanupRepos      = [
              "VideoPlusSensors/mono-repo"
            ];
          };
        }
      ];
    };
  };
}
```

Apply with:

```
nixos-rebuild switch --flake .#my-server
```

The module configures: Docker, Traefik (TLS via Route 53 DNS challenge), the shared `traefik` Docker network, the previews directory, and a weekly cleanup timer.

The module does NOT configure: Tailscale (bring your own), SSH daemon hardening, or firewall rules beyond ports 80, 443, and 8080.

### 2. Add wildcard DNS

In Route 53, add an `A` record:

```
*.changelapse.com  ->  <server Tailscale IP>
```

Traefik uses the Route 53 DNS challenge to issue a single wildcard certificate, so no per-PR DNS changes are needed.

### 3. Add the workflow

Create `.github/workflows/preview.yml` in your application repo:

```yaml
name: Preview Environment

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  deploy:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and push images
        run: |
          # build your images and push to ECR (or any registry)
          docker build -t ${{ secrets.ECR_REGISTRY }}/api:pr-${{ github.event.number }} ./api
          docker push ${{ secrets.ECR_REGISTRY }}/api:pr-${{ github.event.number }}

      - uses: VideoPlusSensors/preview@v1
        with:
          action:          deploy
          project_id:      vpsi
          pr_number:       ${{ github.event.number }}
          preview_host:    ${{ secrets.PREVIEW_HOST }}
          preview_user:    ${{ secrets.PREVIEW_SSH_USER }}
          preview_ssh_key: ${{ secrets.PREVIEW_SSH_KEY }}
          ecr_registry:    ${{ secrets.ECR_REGISTRY }}
          services: |
            [
              {
                "name": "api",
                "image": "${{ secrets.ECR_REGISTRY }}/api:pr-${{ github.event.number }}",
                "port": 8080,
                "path_prefix": "/api",
                "health_check": "/actuator/health"
              },
              {
                "name": "web",
                "image": "${{ secrets.ECR_REGISTRY }}/web:pr-${{ github.event.number }}",
                "port": 3000
              }
            ]

  teardown:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: VideoPlusSensors/preview@v1
        with:
          action:          teardown
          project_id:      vpsi
          pr_number:       ${{ github.event.number }}
          preview_host:    ${{ secrets.PREVIEW_HOST }}
          preview_user:    ${{ secrets.PREVIEW_SSH_USER }}
          preview_ssh_key: ${{ secrets.PREVIEW_SSH_KEY }}
```

### 4. Add GitHub secrets

Add the following as organization-level (or repository-level) secrets:

| Secret            | Description                                          |
|-------------------|------------------------------------------------------|
| `PREVIEW_HOST`    | Tailscale IP address of the preview server           |
| `PREVIEW_SSH_USER`| SSH username on the preview server                   |
| `PREVIEW_SSH_KEY` | SSH private key (contents of the private key file)   |

---

## NixOS Module Options

All options are under `services.preview`.

| Option                    | Type             | Default                  | Description                                                  |
|---------------------------|------------------|--------------------------|--------------------------------------------------------------|
| `enable`                  | bool             | `false`                  | Enable the preview environment server.                       |
| `domain`                  | string           | `"changelapse.com"`      | Base domain for preview URLs.                                |
| `acmeEmail`               | string           | —                        | Email address for Let's Encrypt ACME registration.           |
| `previewsDir`             | string           | `"/opt/previews"`        | Directory where per-PR compose files are stored.             |
| `traefikImage`            | string           | `"traefik:v3.1"`         | Traefik OCI image to use.                                    |
| `aws.accessKeyId`         | string           | —                        | AWS access key ID for Route 53 DNS challenge.                |
| `aws.secretAccessKey`     | string           | —                        | AWS secret access key for Route 53 DNS challenge.            |
| `aws.hostedZoneId`        | string           | —                        | Route 53 hosted zone ID for the domain.                      |
| `cleanupRepos`            | list of strings  | `[]`                     | GitHub repos (`owner/repo`) checked for open PRs at cleanup. |
| `cleanupSchedule`         | string           | `"Sun *-*-* 03:00:00"`   | systemd `OnCalendar` schedule for the orphan cleanup timer.  |

**What the module configures:**
- Docker daemon and OCI containers backend
- Shared `traefik` Docker network (created via a oneshot systemd service)
- Traefik container with HTTPS on 443, HTTP-to-HTTPS redirect on 80, and dashboard on 8080
- Let's Encrypt wildcard certificate via Route 53 DNS challenge
- Previews directory (`previewsDir`) via `systemd.tmpfiles`
- Weekly orphan cleanup systemd service and timer
- System packages: `docker-compose`, `awscli2`, `gh`, `jq`, `curl`
- Firewall open on ports 80, 443, 8080

**What the module does NOT configure:**
- Tailscale installation or enrollment
- SSH daemon
- User accounts or SSH authorized keys
- ECR or other container registry credentials on the server

---

## Action Inputs

| Input                  | Required | Default           | Description                                                      |
|------------------------|----------|-------------------|------------------------------------------------------------------|
| `action`               | yes      | —                 | `"deploy"` or `"teardown"`                                       |
| `project_id`           | yes      | —                 | Project identifier, e.g. `"vpsi"`                                |
| `pr_number`            | yes      | —                 | Pull request number                                              |
| `services`             | no       | `"[]"`            | JSON array of service definitions (required for `deploy`)        |
| `preview_host`         | yes      | —                 | Tailscale IP of the preview server                               |
| `preview_user`         | yes      | —                 | SSH username on the preview server                               |
| `preview_ssh_key`      | yes      | —                 | SSH private key for authenticating to the preview server         |
| `preview_domain`       | no       | `"changelapse.com"` | Base domain for preview URLs                                   |
| `ecr_registry`         | no       | `""`              | ECR registry URL; if set, performs `aws ecr get-login-password`  |
| `aws_region`           | no       | `"us-east-1"`     | AWS region used for ECR login                                    |
| `health_check_timeout` | no       | `"120"`           | Seconds to wait for health checks; `"0"` skips health checks     |

**Output:** `preview_url` — the full HTTPS URL of the deployed environment.

---

## Service Definition

Pass a JSON array to the `services` input. Each element describes one Docker container.

```json
[
  {
    "name": "api",
    "image": "123456789.dkr.ecr.us-east-1.amazonaws.com/api:pr-42",
    "port": 8080,
    "path_prefix": "/api",
    "environment": {
      "SPRING_PROFILES_ACTIVE": "preview",
      "DB_URL": "jdbc:postgresql://db:5432/app"
    },
    "health_check": "/actuator/health"
  },
  {
    "name": "web",
    "image": "123456789.dkr.ecr.us-east-1.amazonaws.com/web:pr-42",
    "port": 3000
  }
]
```

| Field         | Required | Description                                                                 |
|---------------|----------|-----------------------------------------------------------------------------|
| `name`        | yes      | Container and Traefik router name. Must be unique within the services array.|
| `image`       | yes      | Full OCI image reference including tag.                                     |
| `port`        | yes      | Container port that Traefik forwards traffic to.                            |
| `path_prefix` | no       | URL path prefix, e.g. `"/api"`. Omit for root (`/`).                       |
| `environment` | no       | Key/value map of environment variables injected into the container.         |
| `health_check`| no       | HTTP path polled by the action until it returns `{"status":"UP"}` (or `ok`/`healthy`). Also sets a Docker healthcheck on the container. |

---

## Routing

Traefik routes requests using Docker labels generated by `scripts/generate-compose.sh`.

- A service with `path_prefix` gets the rule `Host(`...`) && PathPrefix(`/api`)`.
- A service without `path_prefix` gets `Host(`...`)` only (matches all paths).

When multiple services share the same hostname, the more specific `PathPrefix` rule takes priority because Traefik ranks rules by length and specificity. Put catchall services (e.g. a frontend SPA) last and omit their `path_prefix` so they handle everything not matched by a more specific backend route.

---

## SSH Key Pair

Generate a dedicated key pair for the preview server:

```
ssh-keygen -t ed25519 -f ~/.ssh/preview_deploy -C "preview-deploy" -N ""
```

Add the public key (`~/.ssh/preview_deploy.pub`) to `~/.ssh/authorized_keys` on the preview server for the `PREVIEW_SSH_USER` account. Store the private key contents as the `PREVIEW_SSH_KEY` secret in GitHub.
