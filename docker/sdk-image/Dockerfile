# Responsibility: derive the harness SDK image from an official snapshot SDK
# container (openwrt/sdk). Snapshot containers ship only setup.sh, which
# downloads the ~280 MB SDK from the OpenWrt mirror at run time; running it
# here, once, moves that download out of every build job.
#
# Build:
#   docker build --pull --build-arg BASE=docker.io/openwrt/sdk:<arch>-<line> \
#     docker/sdk-image
#
# The line of /builder/.sdk-archive is the verified "<sha256> *<archive>" line
# printed by setup.sh; scripts/sdk-image-ensure.sh copies it into image labels.
# setup.sh is removed because the entrypoint of openwrt/gh-action-sdk runs
# `[ ! -f setup.sh ] || bash setup.sh`, and a second run would fail on the
# keys/ directory that setup.sh already deleted.
ARG BASE
FROM ${BASE}

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN bash setup.sh | tee /tmp/setup.log \
    && archive=$(grep -E '^[0-9a-f]{64} [*]' /tmp/setup.log) \
    && [ "$(printf '%s\n' "${archive}" | wc -l)" -eq 1 ] \
    && printf '%s\n' "${archive}" > /builder/.sdk-archive \
    && rm -f setup.sh /tmp/setup.log
