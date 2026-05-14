# Emphe Migration Plan

Migration from Docker Compose preview environments to NixOS-native systemd-nspawn containers via extra-container with Docker-in-nspawn.

## Phases

| Phase | Task | Timeline | Depends On |
|-------|------|----------|------------|
| [Phase 0](./00-spike-docker-in-nspawn.md) | Spike: Docker-in-nspawn validation | 2-3 days | — |
| [Phase 1](./01-core-cli.md) | Core CLI: emphe create/destroy/list | ~1 week | Phase 0 |
| [Phase 2](./02-host-module.md) | Host NixOS module update | 3-4 days | Phase 0 |
| [Phase 3](./03-vpsi-integration.md) | VPSI integration | 3-4 days | Phase 1 + 2 |
| [Phase 4](./04-cleanup-and-fischerfarms.md) | Cleanup + Fischer Farms | 3-4 days | Phase 3 |

Phases 1 and 2 can be worked in parallel after Phase 0 passes.

## Architecture Summary

- **Container runtime:** systemd-nspawn via extra-container
- **Inside each container:** Docker daemon running compose stack (same images as prod)
- **Reverse proxy:** Traefik with file provider (emphe writes/deletes YAML route files)
- **Networking:** Private veth pair per container (10.100.{N}.0/24), NAT for outbound
- **CLI:** `emphe create|destroy|list|cleanup` (bash)
- **Config:** `/etc/emphe/config.yaml` (project registry)
- **Project contract:** Each project provides `emphe-container.nix` in its repo

## Key Technical Decisions

- **Docker-in-nspawn** requires: `extraFlags` for keyctl+bpf syscalls, forced cgroup v2 (`SYSTEMD_NSPAWN_UNIFIED_HIERARCHY=1`), privileged containers (NixOS default)
- **Traefik file provider** over Docker labels — nspawn containers aren't visible to Docker's label discovery
- **IP allocation** via scanning existing containers — no persistent state file needed
- **URL format:** `{project}-pr{N}.changelapse.com`

## Go/No-Go Gate

Phase 0 is the critical spike. If Docker cannot run reliably inside nspawn on this host, fallback options:
1. Podman instead of Docker inside nspawn
2. nspawn for network isolation only, Docker stays on host
3. Improve current Docker Compose approach without nspawn
