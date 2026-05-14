# Phase 0: Spike — Docker-in-nspawn Validation

**Goal:** Prove Docker runs reliably inside an extra-container nspawn container on the actual NixOS host. This is the go/no-go gate for the entire architecture.

**Timeline:** 2-3 days

---

## Tasks

### 0.1 Install extra-container on the host

- Add `extra-container` to the flake inputs or system packages
- Verify `extra-container create --help` works
- Confirm extra-container version supports all needed NixOS container options

### 0.2 Create a minimal nspawn container with Docker

Write a test container config:

```nix
{ config, pkgs, lib, ... }:
{
  containers.spike-docker = {
    privateNetwork = true;
    hostAddress = "10.100.99.1";
    localAddress = "10.100.99.2";

    extraFlags = [
      "--system-call-filter=keyctl"
      "--system-call-filter=bpf"
    ];

    config = { pkgs, ... }: {
      virtualisation.docker.enable = true;
      environment.systemPackages = [ pkgs.docker-compose ];
      networking.firewall.allowedTCPPorts = [ 8080 ];
    };
  };

  systemd.services."container@spike-docker".environment = {
    SYSTEMD_NSPAWN_USE_CGNS = "0";
    SYSTEMD_NSPAWN_UNIFIED_HIERARCHY = "1";
  };
}
```

Run: `extra-container create --start spike-docker.nix`

### 0.3 Verify Docker works inside the container

```bash
# Enter the container
nixos-container root-login spike-docker

# Inside:
docker info          # Should show overlay2 driver, cgroup v2
docker run hello-world
docker run -d -p 8080:80 nginx
curl localhost:8080  # Should return nginx welcome page
```

### 0.4 Verify host-to-container networking

From the host:
```bash
curl http://10.100.99.2:8080   # Should reach nginx inside container
```

Verify NAT for outbound (container can pull images):
```bash
# Inside container:
docker pull alpine
```

If outbound fails, configure NAT on host:
```nix
networking.nat.enable = true;
networking.nat.internalInterfaces = [ "ve-+" ];
networking.nat.externalInterface = "tailscale0";  # or primary interface
```

### 0.5 Test ECR pull inside container

```bash
# Bind-mount AWS credentials into container, then inside:
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <registry>
docker pull <ecr-image>
```

### 0.6 Test docker-compose stack inside container

Create a minimal compose file with 2-3 services (e.g., nginx + mongo) and verify they start, communicate, and the exposed port is reachable from the host.

### 0.7 Test container destroy and cleanup

```bash
extra-container destroy spike-docker
# Verify: no leftover veth interfaces, no orphaned processes, IP freed
```

---

## Success Criteria

- [ ] Docker daemon starts inside nspawn container
- [ ] overlay2 storage driver works
- [ ] Container can pull images from Docker Hub and ECR
- [ ] docker-compose multi-service stack runs inside container
- [ ] Host can reach published ports via container's private IP (10.100.99.2:8080)
- [ ] Container has outbound internet access (NAT working)
- [ ] Container destroys cleanly with no resource leaks

## Fallback

If Docker-in-nspawn fails:
1. Try podman instead of Docker (no daemon, potentially fewer cgroup issues)
2. Try `--network-veth` with Docker on host (nspawn for network isolation only)
3. Abandon nspawn, keep current Docker Compose approach with improvements
