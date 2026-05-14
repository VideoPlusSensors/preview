# Phase 2: Host NixOS Module Update

**Goal:** Update `nixos/module.nix` to support the emphe architecture — file provider for Traefik, extra-container, NAT, emphe CLI installation, state directories.

**Timeline:** 3-4 days

**Depends on:** Phase 0 (spike confirms NAT and Traefik config)

---

## Tasks

### 2.1 Add extra-container to flake inputs

Update `flake.nix`:
- Add `extra-container` flake input
- Pass it through to the NixOS module
- Ensure `extra-container` binary is available in system packages

### 2.2 Add Traefik file provider

Update Traefik container command in `module.nix`:

```nix
cmd = existing-flags ++ [
  "--providers.file.directory=/etc/traefik/dynamic/"
  "--providers.file.watch=true"
];
```

Add volume mount:
```nix
volumes = existing-volumes ++ [
  "/etc/traefik/dynamic/:/etc/traefik/dynamic/:ro"
];
```

Keep the Docker provider active — Traefik itself still runs as a Docker container on the host. The file provider is additive for nspawn container routing.

### 2.3 Configure NAT for container networking

Add to module config:

```nix
networking.nat.enable = true;
networking.nat.internalInterfaces = [ "ve-+" ];
networking.nat.externalInterface = "<primary-interface>";  # make configurable
```

Add NixOS option:
```nix
natInterface = mkOption {
  type = types.str;
  default = "tailscale0";
  description = "External interface for NAT masquerade (outbound from containers).";
};
```

### 2.4 Add emphe configuration options

New options under `services.preview`:

```nix
emphe = {
  configFile = mkOption {
    type = types.path;
    default = "/etc/emphe/config.yaml";
    description = "Path to emphe project registry config.";
  };

  stateDir = mkOption {
    type = types.str;
    default = "/var/lib/emphe";
    description = "Base directory for emphe state (repos, etc).";
  };
};
```

### 2.5 Create emphe state directories

Add to `systemd.tmpfiles.rules`:

```nix
systemd.tmpfiles.rules = [
  "d ${cfg.previewsDir} 0755 root root -"
  "d ${cfg.emphe.stateDir} 0755 root root -"
  "d ${cfg.emphe.stateDir}/repos 0755 root root -"
  "d /etc/traefik/dynamic 0755 root root -"
  "d /etc/emphe 0755 root root -"
];
```

### 2.6 Install emphe CLI

Package the emphe bash script and add to system packages:

```nix
environment.systemPackages = with pkgs; [
  docker-compose
  awscli2
  gh
  jq
  curl
  yq-go          # for YAML parsing in emphe CLI
  extra-container # from flake input
  (writeShellScriptBin "emphe" (builtins.readFile ../scripts/emphe))
];
```

### 2.7 Update cleanup service for extra-container

Adapt `cleanup-orphaned-previews.sh`:
- Change from scanning `docker compose ls` to `extra-container list`
- Change teardown from `docker compose down` to `extra-container destroy`
- Also clean up Traefik config files and repo clones
- Update container name parsing: `{project}-pr{N}` format

Or replace the cleanup script with `emphe cleanup` subcommand that reuses destroy logic.

### 2.8 Update flake.nix outputs

Ensure the flake still exports the module correctly and includes the new dependencies:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    extra-container.url = "github:erikarvstedt/extra-container";
  };

  outputs = { self, nixpkgs, extra-container }: {
    nixosModules.default = import ./nixos/module.nix;
    nixosModules.preview = import ./nixos/module.nix;
  };
}
```

### 2.9 Test module rebuild

On the NixOS host:
1. `nixos-rebuild switch` with updated module
2. Verify Traefik restarts with file provider enabled
3. Verify `/etc/traefik/dynamic/` directory exists and is mounted in Traefik container
4. Verify `emphe` command is available
5. Verify NAT rules are active: `iptables -t nat -L` shows masquerade for `ve-+`
6. Manually write a test Traefik config file and verify Traefik picks it up

---

## Success Criteria

- [ ] `nixos-rebuild switch` succeeds with updated module
- [ ] Traefik container has file provider enabled and `/etc/traefik/dynamic/` mounted
- [ ] Manually placing a YAML file in `/etc/traefik/dynamic/` creates a Traefik route within seconds
- [ ] `emphe` command is on PATH and shows usage
- [ ] `extra-container` command is on PATH
- [ ] NAT masquerade is active for `ve-+` interfaces
- [ ] State directories exist: `/var/lib/emphe/repos/`, `/etc/emphe/`, `/etc/traefik/dynamic/`
- [ ] Existing Traefik Docker provider still works (Traefik's own container labels still function)
- [ ] Cleanup timer updated for extra-container
