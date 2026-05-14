# Phase 3: VPSI Integration

**Goal:** Write VPSI's `emphe-container.nix`, test the full flow from `emphe create` to a live preview environment with the real application stack (React + Java Spring + MongoDB).

**Timeline:** 3-4 days

**Depends on:** Phase 1 (CLI working) + Phase 2 (host module deployed)

---

## Tasks

### 3.1 Write VPSI's emphe-container.nix

Create `emphe-container.nix` in the VPSI mono-repo root:

```nix
{ pkgs, ... }:
{
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.docker-compose ];

  systemd.services.preview-app = {
    description = "VPSI preview application stack";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/app";
    };
    script = ''
      ${pkgs.docker-compose}/bin/docker compose up -d
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
```

Adjust based on actual VPSI compose structure — may need multiple ports, specific env vars, etc.

### 3.2 Verify VPSI's docker-compose.yml works inside nspawn

The compose file needs to:
- Reference ECR image tags (not build from source)
- Expose port 8080 (or whatever the app gateway port is)
- Define all services: React frontend, Java Spring API, MongoDB
- Not depend on external Docker networks (no `traefik` network references)

May need a separate `docker-compose.preview.yml` if the main compose file has dependencies that don't apply in preview (e.g., external networks, host-specific volumes).

### 3.3 Handle ECR authentication inside the container

Options (pick one during implementation):
1. **Bind-mount host Docker config:** Mount `~/.docker/config.json` from host into container
2. **Bind-mount AWS credentials:** Mount sops-decrypted AWS creds, run `ecr get-login-password` inside container
3. **Pre-pull on host, share images:** Pull images on host Docker, export/import into container's Docker (complex, avoid)

Recommended: bind-mount AWS credentials and add ECR login to the container's startup script:

```nix
systemd.services.ecr-login = {
  description = "ECR Docker login";
  after = [ "docker.service" ];
  before = [ "preview-app.service" ];
  requires = [ "docker.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  script = ''
    ${pkgs.awscli2}/bin/aws ecr get-login-password --region us-east-1 \
      | ${pkgs.docker}/bin/docker login --username AWS --password-stdin <registry-url>
  '';
};
```

### 3.4 Handle environment variable injection

The container needs platform-injected env vars available to Docker Compose services. Options:
1. Write a `.env` file to `/app/.env` that docker-compose picks up
2. Pass env vars through the systemd service environment

Recommended: emphe generates a `.env` file at container creation time:

```bash
# In emphe create, write .env to the cloned repo dir before container starts
cat > "${REPO_DIR}/.env.preview" <<EOF
APP_ENV=preview
PR_NUMBER=${PR}
PROJECT=${PROJECT}
DOMAIN=${PROJECT}-pr${PR}.${DOMAIN}
EOF
```

Bind-mount this into the container. Compose file references it.

### 3.5 Test full create flow

```bash
emphe create --project vpsi --pr <real-pr-number>
```

Verify:
1. Repo cloned with correct branch
2. Container created and running (`extra-container list`)
3. Docker daemon running inside container
4. ECR login succeeds
5. `docker compose up` pulls images and starts services
6. React frontend accessible at `https://vpsi-pr<N>.changelapse.com`
7. Spring API accessible (likely behind same hostname, different path)
8. MongoDB running and app can connect

### 3.6 Test full destroy flow

```bash
emphe destroy --project vpsi --pr <same-pr-number>
```

Verify:
1. Container stopped and removed
2. Traefik route gone (URL returns 404)
3. Repo directory cleaned up
4. No orphaned Docker images or volumes on host

### 3.7 Test concurrent environments

Create two VPSI preview environments for different PRs simultaneously:

```bash
emphe create --project vpsi --pr 10
emphe create --project vpsi --pr 11
emphe list
```

Verify:
- Different subnet IPs assigned
- Both URLs accessible independently
- Destroying one doesn't affect the other

### 3.8 Debug and iterate on startup timing

The container startup sequence is: nspawn boots → systemd starts → Docker daemon starts → ECR login → docker compose up → services healthy.

This chain has timing dependencies. Ensure:
- `After=` and `Requires=` dependencies are correct in systemd services
- Docker daemon is fully ready before compose runs (may need `docker info` wait loop)
- Total startup time is acceptable (<120s target)

---

## Success Criteria

- [ ] `emphe create --project vpsi --pr <N>` brings up full VPSI stack (React + Spring + MongoDB)
- [ ] Frontend accessible at `https://vpsi-pr<N>.changelapse.com` on Tailnet
- [ ] API endpoints functional
- [ ] MongoDB running and app connected
- [ ] ECR images pulled successfully inside container
- [ ] `emphe destroy` cleanly removes everything
- [ ] Two concurrent VPSI environments work without interference
- [ ] Startup time under 120 seconds
