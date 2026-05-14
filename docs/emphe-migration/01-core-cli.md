# Phase 1: Core CLI — emphe create/destroy/list

**Goal:** Working `emphe` bash CLI that creates and destroys nspawn containers with Docker inside, allocates IPs, and manages Traefik routes.

**Timeline:** ~1 week

**Depends on:** Phase 0 (spike passes)

---

## Tasks

### 1.1 Create project config file format

Define and create `/etc/emphe/config.yaml`:

```yaml
domain: changelapse.com

projects:
  vpsi:
    repo: VideoPlusSensors/mono-repo
    app_port: 8080
  ff:
    repo: owner/fischerfarms
    app_port: 8080
```

### 1.2 Write config parser

Bash function that reads config.yaml using `yq` and extracts project settings:
- `get_project_config <project>` — returns repo, app_port
- `get_domain` — returns domain
- Validate project exists, fail with clear error if not

### 1.3 Write IP subnet allocator

Function `allocate_subnet`:
- Parse output of `extra-container list` to find used container IPs
- Find first unused ID in range 1-254 for the `10.100.{N}.0/24` subnet
- Return the subnet ID
- Handle the empty case (no containers running, start at 1)

### 1.4 Write NixOS container config generator

Function `generate_container_nix <project> <pr> <subnet_id> <repo_dir> <app_port>`:
- Generates a `.nix` file at `/tmp/emphe-{project}-pr{pr}.nix`
- Sets `privateNetwork`, `hostAddress`, `localAddress` from subnet ID
- Adds `extraFlags` for keyctl + bpf syscall filters
- Adds `bindMounts` for the cloned repo → `/app`
- Imports the project's `emphe-container.nix` from the cloned repo
- Sets cgroup v2 environment variables on the container service
- Injects platform environment variables (APP_ENV, PR_NUMBER, PROJECT)

### 1.5 Write Traefik dynamic config generator

Function `write_traefik_config <project> <pr> <subnet_id> <app_port>`:
- Writes `/etc/traefik/dynamic/{project}-pr{pr}.yml`
- Router rule: `Host(\`{project}-pr{pr}.{domain}\`)`
- Entry point: `websecure`
- TLS cert resolver: `letsencrypt`
- Service URL: `http://10.100.{subnet_id}.2:{app_port}`

Function `remove_traefik_config <project> <pr>`:
- Deletes `/etc/traefik/dynamic/{project}-pr{pr}.yml`

### 1.6 Implement `emphe create`

Full flow:
1. Parse args: `--project` and `--pr` (required)
2. Read project config
3. Check container doesn't already exist (idempotency)
4. Fetch PR branch name via `gh pr view`
5. Clone repo to `/var/lib/emphe/repos/{project}-pr{pr}/`
6. Verify `emphe-container.nix` exists in cloned repo
7. Allocate subnet
8. Generate container nix config
9. `extra-container create --start <config>`
10. Wait for container to be running (poll `extra-container list`)
11. Write Traefik dynamic config
12. Print URL: `https://{project}-pr{pr}.{domain}`

Error handling:
- If any step fails, clean up partial state (remove clone dir, remove traefik config)
- Exit with non-zero and a clear error message

### 1.7 Implement `emphe destroy`

Full flow:
1. Parse args: `--project` and `--pr`
2. `extra-container destroy {project}-pr{pr}`
3. Remove Traefik config file
4. Remove cloned repo directory
5. Print confirmation

Idempotency: don't fail if container or files already gone.

### 1.8 Implement `emphe list`

- Run `extra-container list`
- Filter to emphe-managed containers (naming convention: `{project}-pr{N}`)
- For each, show: container name, IP, status, URL
- Table format for readability

### 1.9 Wire up subcommand dispatch

Main `emphe` script entry point:
```bash
case "${1:-}" in
  create)  shift; emphe_create "$@" ;;
  destroy) shift; emphe_destroy "$@" ;;
  list)    shift; emphe_list "$@" ;;
  *)       usage ;;
esac
```

### 1.10 Test with minimal container (nginx)

Before integrating VPSI's real stack:
1. Create a test project with a trivial `emphe-container.nix` that runs nginx
2. `emphe create --project test --pr 1`
3. Verify URL is accessible from Tailnet
4. `emphe destroy --project test --pr 1`
5. Verify clean teardown

---

## Success Criteria

- [ ] `emphe create --project test --pr 1` brings up an nspawn container with Docker + nginx
- [ ] Container gets a unique private IP (10.100.x.2)
- [ ] Traefik routes `test-pr1.changelapse.com` to the container
- [ ] `emphe list` shows the running environment with IP and URL
- [ ] `emphe destroy --project test --pr 1` removes container, route, and clone
- [ ] Creating a second environment gets a different subnet (no collision)
- [ ] Error cases: missing project in config, missing emphe-container.nix, container already exists
