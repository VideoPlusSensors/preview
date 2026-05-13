{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  cfg = config.services.preview;

  useEnvFile = cfg.aws.environmentFile != null;

  cleanupScript = ./.. + "/scripts/cleanup-orphaned-previews.sh";
in
{
  options.services.preview = {
    enable = mkEnableOption "PR preview environment server";

    domain = mkOption {
      type = types.str;
      default = "changelapse.com";
      description = "Base domain for preview environments.";
    };

    acmeEmail = mkOption {
      type = types.str;
      description = "Email address for Let's Encrypt ACME registration.";
    };

    previewsDir = mkOption {
      type = types.str;
      default = "/opt/previews";
      description = "Directory where per-PR compose files are stored.";
    };

    traefikImage = mkOption {
      type = types.str;
      default = "traefik:v3.1";
      description = "Traefik OCI image to use.";
    };

    aws = {
      accessKeyId = mkOption {
        type = types.str;
        default = "";
        description = "AWS access key ID for Route 53 DNS challenge. Ignored if environmentFile is set.";
      };

      secretAccessKey = mkOption {
        type = types.str;
        default = "";
        description = "AWS secret access key for Route 53 DNS challenge. Ignored if environmentFile is set.";
      };

      hostedZoneId = mkOption {
        type = types.str;
        default = "";
        description = "Route 53 hosted zone ID for the domain. Ignored if environmentFile is set.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing AWS environment variables for the Traefik
          DNS-01 challenge. Expected format (one per line):
            AWS_ACCESS_KEY_ID=...
            AWS_SECRET_ACCESS_KEY=...
            AWS_HOSTED_ZONE_ID=...
          When set, the plain-text aws.* options are ignored. Use this with
          sops-nix or agenix to avoid secrets in the Nix store.
        '';
      };
    };

    cleanupRepos = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of GitHub repos (owner/repo) to check for open PRs during cleanup.";
      example = [
        "VideoPlusSensors/preview"
        "VideoPlusSensors/mono-repo"
      ];
    };

    cleanupSchedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 03:00:00";
      description = "systemd OnCalendar schedule for the cleanup timer.";
    };
  };

  config = mkIf cfg.enable {
    # Docker
    virtualisation.docker.enable = true;

    # OCI containers backend
    virtualisation.oci-containers.backend = "docker";

    # Create the shared traefik network before any containers start
    systemd.services.docker-network-traefik = {
      description = "Create traefik Docker network";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.docker}/bin/docker network create traefik || true";
      };
    };

    # Traefik reverse proxy
    virtualisation.oci-containers.containers.traefik = {
      image = cfg.traefikImage;

      cmd = [
        "--api.dashboard=true"
        "--api.insecure=true"
        "--providers.docker=true"
        "--providers.docker.exposedbydefault=false"
        "--providers.docker.network=traefik"
        "--entrypoints.web.address=:80"
        "--entrypoints.web.http.redirections.entrypoint.to=websecure"
        "--entrypoints.web.http.redirections.entrypoint.scheme=https"
        "--entrypoints.websecure.address=:443"
        "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
        "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=route53"
        "--certificatesresolvers.letsencrypt.acme.email=${cfg.acmeEmail}"
        "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      ];

      environment = lib.mkIf (!useEnvFile) {
        AWS_ACCESS_KEY_ID = cfg.aws.accessKeyId;
        AWS_SECRET_ACCESS_KEY = cfg.aws.secretAccessKey;
        AWS_HOSTED_ZONE_ID = cfg.aws.hostedZoneId;
      };

      environmentFiles = lib.mkIf useEnvFile [
        cfg.aws.environmentFile
      ];

      ports = [
        "80:80"
        "443:443"
        "8080:8080"
      ];

      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:ro"
        "traefik-certs:/letsencrypt"
      ];

      extraOptions = [ "--network=traefik" ];
    };

    # Ensure traefik container waits for the network to exist
    systemd.services."docker-traefik" = {
      after = [ "docker-network-traefik.service" ];
      requires = [ "docker-network-traefik.service" ];
    };

    # Ensure previews directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.previewsDir} 0755 root root -"
    ];

    # Cleanup service
    systemd.services.preview-cleanup = {
      description = "Remove Docker compose stacks for closed/merged PRs";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${cleanupScript} ${lib.concatStringsSep " " cfg.cleanupRepos}";
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.docker
              pkgs.bash
              pkgs.jq
              pkgs.gh
              pkgs.awscli2
            ]
          }"
          "PREVIEWS_DIR=${cfg.previewsDir}"
        ];
      };
    };

    # Cleanup timer
    systemd.timers.preview-cleanup = {
      description = "Timer for preview-cleanup service";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.cleanupSchedule;
        Persistent = true;
      };
    };

    # System packages
    environment.systemPackages = with pkgs; [
      docker-compose
      awscli2
      gh
      jq
      curl
    ];

    # Firewall
    networking.firewall.allowedTCPPorts = [
      80
      443
      8080
    ];
  };
}
