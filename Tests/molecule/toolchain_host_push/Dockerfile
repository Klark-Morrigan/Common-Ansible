# Build-once container image shared by the toolchain_host_push molecule
# scenarios (default + reconcile + remove). Lives at the parent of the
# scenario directories rather than duplicated inside each, so the image
# definition has a single source of truth.
#
# Why a custom Dockerfile instead of plain docker.io/library/ubuntu:24.04:
# the ubuntu:24.04 base image no longer ships /usr/bin/python3 in its
# default layer. Ansible modules execute on the managed host via a Python
# interpreter, so the first ansible.builtin.* task fails at
#   /bin/sh: 1: /usr/bin/python3: not found
# before prepare.yml can apt-install anything. Baking python3 (plus the
# tar/gzip/sudo set the role and the fixture depend on) into the image at
# build time gives a working interpreter from container create onward.
#
# Why these four packages:
#   python3  - Ansible AnsiballZ interpreter on the managed host.
#   sudo     - The role's `become: true` tasks rely on sudo on the target.
#   tar      - ansible.builtin.unarchive shells out to tar; the fixture
#              also builds its fake tarballs with tar (wrapper-dir layout).
#   gzip     - tar -z shells out to gzip for the .tar.gz fixtures.
#
# Build once via:
#   docker build \
#       -t common-ansible/toolchain-host-push-base:24.04 \
#       -f Tests/molecule/toolchain_host_push/Dockerfile \
#       Tests/molecule/toolchain_host_push
# Every scenario consumes the resulting tag via `pre_build_image: true`.
FROM docker.io/library/ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 sudo tar gzip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
