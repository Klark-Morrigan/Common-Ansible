# Build-once container image for the docker role molecule scenario.
#
# Why a bespoke image (not the section-1/2 toolchain-host-push-base): the
# docker role enables/starts a systemd service and the Docker daemon has to
# actually run so `verify` can call `docker ps`. That needs two things the
# sleep-infinity base image lacks:
#   1. systemd as PID 1 - the role's systemd_service task manages a real
#      unit, so the container must boot systemd (command /usr/sbin/init in
#      molecule.yml), not sit on sleep infinity.
#   2. a working AnsiballZ interpreter - ubuntu:24.04 no longer ships
#      /usr/bin/python3 in its default layer, so bake it in (same reason
#      the host-push Dockerfile does).
#
# The privileged / cgroup wiring that lets the inner daemon start
# (docker-in-docker) is set on the platform in molecule.yml, not here.
#
# Why these packages:
#   systemd, systemd-sysv - PID 1 init so the role can enable+start docker.
#   python3               - Ansible AnsiballZ interpreter on the target.
#   sudo                  - backs the role's `become: true` tasks.
# ca-certificates and curl are intentionally NOT baked in: the role installs
# them itself (its first repo step), so leaving them out keeps that step
# under test rather than masked by the image.
#
# Build once via:
#   docker build \
#       -t common-ansible/docker-systemd-base:24.04 \
#       -f Tests/molecule/docker/Dockerfile \
#       Tests/molecule/docker
# The scenario consumes the resulting tag via `pre_build_image: true`.
FROM docker.io/library/ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv python3 sudo \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# systemd expects SIGRTMIN+3 to trigger a clean shutdown; without this the
# container ignores `docker stop` and is killed after the timeout.
STOPSIGNAL SIGRTMIN+3
