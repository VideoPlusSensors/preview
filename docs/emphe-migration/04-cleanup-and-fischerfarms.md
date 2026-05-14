# Phase 4: Cleanup + Fischer Farms

**Goal:** Adapt the orphan cleanup system for extra-container, onboard Fischer Farms as the second project, and finalize the migration.

**Timeline:** 3-4 days

**Depends on:** Phase 3 (VPSI working end-to-end)

---

## Tasks

### 4.1 Implement emphe cleanup subcommand

Add `emphe cleanup` that replaces the current `cleanup-orphaned-previews.sh`:

```bash
emphe cleanup
```

Logic:
1. List all emphe-managed containers via `extra-container list`
2. For each container, parse project and PR number from the name (`{project}-pr{N}`)
3. Look up the project's repo from `/etc/emphe/config.yaml`
4. Check PR state via `gh pr view <N> --repo <repo> --json state -q .state`
5. If PR is not OPEN, run `emphe destroy --project <project> --pr <N>`
6. Log all actions with timestamps

### 4.2 Update cleanup systemd service

In `module.nix`, change the cleanup service to use `emphe cleanup` instead of the old bash script:

```nix
systemd.services.preview-cleanup = {
  description = "Remove emphe environments for closed/merged PRs";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${emphe}/bin/emphe cleanup";
    Environment = [ "PATH=..." ];
  };
};
```

Keep the existing timer schedule (weekly Sunday 3:00 AM).

### 4.3 Test cleanup with a closed PR

1. Create an environment for a PR that is already closed/merged
2. Run `emphe cleanup`
3. Verify the environment is destroyed
4. Verify an environment for an open PR is NOT destroyed

### 4.4 Write Fischer Farms emphe-container.nix

Create `emphe-container.nix` in the Fischer Farms repo. This project uses a different stack — adjust accordingly:

- Determine Fischer Farms' services (web app, database type, etc.)
- Enable Docker, docker-compose
- Configure ports
- Handle any project-specific env vars or config

### 4.5 Add Fischer Farms to config

Update `/etc/emphe/config.yaml` on the host:

```yaml
projects:
  vpsi:
    repo: VideoPlusSensors/mono-repo
    app_port: 8080
  ff:
    repo: owner/fischerfarms
    app_port: 8080
```

### 4.6 Test Fischer Farms end-to-end

```bash
emphe create --project ff --pr <N>
# Verify URL accessible
emphe list
# Verify both vpsi and ff environments show
emphe destroy --project ff --pr <N>
```

### 4.7 Test concurrent cross-project environments

Run VPSI and Fischer Farms environments simultaneously:

```bash
emphe create --project vpsi --pr 10
emphe create --project ff --pr 5
emphe list
```

Verify:
- Different subnets, different URLs, no interference
- Both accessible concurrently
- Destroying one doesn't affect the other

### 4.8 Remove old Docker Compose scripts (or deprecate)

Once both projects are working on emphe:
- Consider removing or archiving: `scripts/deploy.sh`, `scripts/teardown.sh`, `scripts/generate-compose.sh`
- Or keep them alongside for rollback during transition
- Update `action.yml` to note the new approach (or leave for Phase 5 GH Action rework)

### 4.9 Document the project contract

Write minimal documentation for future projects that want preview environments. Cover:
- What `emphe-container.nix` must contain
- Required: `virtualisation.docker.enable`, firewall port, systemd service for compose
- How to add a project to the config
- How to test locally before deploying

### 4.10 Memory / resource check

With environments running for both projects:
- Check host memory usage (`free -h`, `systemd-cgtop`)
- Check per-container memory (Docker daemon overhead + services)
- Note baseline for future resource limit decisions
- Identify if 16GB allows the target 3-8 concurrent environments

---

## Success Criteria

- [ ] `emphe cleanup` correctly destroys environments for closed PRs
- [ ] `emphe cleanup` leaves open PR environments untouched
- [ ] Cleanup timer fires on schedule and works end-to-end
- [ ] Fischer Farms `emphe-container.nix` written and working
- [ ] `emphe create --project ff --pr <N>` brings up Fischer Farms stack
- [ ] Cross-project concurrent environments work (vpsi + ff at same time)
- [ ] Memory usage documented for capacity planning
- [ ] Old scripts deprecated or removed
- [ ] Project contract documented for future onboarding
