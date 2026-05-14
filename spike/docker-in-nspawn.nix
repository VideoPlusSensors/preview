# Spike: Docker-in-nspawn validation
#
# Proves Docker can run inside a NixOS systemd-nspawn container.
# This is the go/no-go gate for migrating preview environments
# from Docker Compose to nspawn containers.
#
# Usage:
#   extra-container create --start spike/docker-in-nspawn.nix
#
# Verification (from host):
#   nixos-container root-login spike-docker
#   docker info            # expect overlay2 driver, cgroup v2
#   docker run hello-world
#   docker run -d -p 8080:80 nginx
#   curl localhost:8080    # nginx welcome page
#
# From host:
#   curl http://10.100.99.2:8080   # reach nginx inside container
#
# Cleanup:
#   extra-container destroy spike-docker
{
  config,
  pkgs,
  lib,
  ...
}:
{
  # ---------------------------------------------------------------------------
  # Container definition
  # ---------------------------------------------------------------------------
  containers.spike-docker = {
    privateNetwork = true;
    hostAddress = "10.100.99.1";
    localAddress = "10.100.99.2";

    # Docker inside nspawn needs keyctl (for kernel keyring) and bpf (for
    # cgroup/networking BPF programs). Each flag must be a separate list
    # element — nixpkgs#198857.
    extraFlags = [
      "--system-call-filter=keyctl"
      "--system-call-filter=bpf"
    ];

    config =
      { pkgs, ... }:
      {
        # Docker daemon
        virtualisation.docker.enable = true;

        # Useful tooling inside the container
        environment.systemPackages = [ pkgs.docker-compose ];

        # Allow traffic to reach services published by Docker
        networking.firewall.allowedTCPPorts = [ 8080 ];

        # Let NixOS manage the system inside the container
        system.stateVersion = "24.11";
      };
  };

  # ---------------------------------------------------------------------------
  # Cgroup v2 — required for Docker inside nspawn
  # ---------------------------------------------------------------------------
  # These environment variables must be set on the *host-side* systemd service
  # that launches the nspawn container, not inside the container itself.
  #   SYSTEMD_NSPAWN_USE_CGNS=0       — disable cgroup namespacing so Docker
  #                                      can manage its own cgroups
  #   SYSTEMD_NSPAWN_UNIFIED_HIERARCHY=1 — force cgroup v2 unified hierarchy
  systemd.services."container@spike-docker".environment = {
    SYSTEMD_NSPAWN_USE_CGNS = "0";
    SYSTEMD_NSPAWN_UNIFIED_HIERARCHY = "1";
  };

  # ---------------------------------------------------------------------------
  # Host-side NAT — gives the container outbound internet access
  # ---------------------------------------------------------------------------
  # The ve-+ wildcard matches all veth interfaces created by nspawn containers.
  networking.nat.enable = true;
  networking.nat.internalInterfaces = [ "ve-+" ];
}
