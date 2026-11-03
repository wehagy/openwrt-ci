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
# shfmt: the init-script format check of `make package/<pkg>/check` runs it;
# the official SDK container does not ship it, so the check validated nothing
# (`find: 'shfmt': No such file or directory`). It is installed from the
# release binary of mvdan/sh, verified against the sha256 below, and the build
# fails if it is missing or reports another version. The sha256 of this file is
# an image label (scripts/sdk-image-ensure.sh): a change here rebuilds the
# image even when it is younger than the maximum age.
#
# setup.sh is removed because the entrypoint of openwrt/gh-action-sdk runs
# `[ ! -f setup.sh ] || bash setup.sh`, and a second run would fail on the
# keys/ directory that setup.sh already deleted.
ARG BASE
FROM ${BASE}

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# shfmt version (release of github.com/mvdan/sh)
ARG SHFMT_VERSION=3.14.1
# sha256 of shfmt_v${SHFMT_VERSION}_linux_amd64 (digest of the release asset)
ARG SHFMT_SHA256=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf

USER root
RUN curl -fsSL -o /usr/local/bin/shfmt \
      "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
    && printf '%s  %s\n' "${SHFMT_SHA256}" /usr/local/bin/shfmt | sha256sum -c - \
    && chmod 0755 /usr/local/bin/shfmt \
    && [ "$(shfmt --version)" = "v${SHFMT_VERSION}" ]
USER buildbot

RUN bash setup.sh | tee /tmp/setup.log \
    && archive=$(grep -E '^[0-9a-f]{64} [*]' /tmp/setup.log) \
    && [ "$(printf '%s\n' "${archive}" | wc -l)" -eq 1 ] \
    && printf '%s\n' "${archive}" > /builder/.sdk-archive \
    && rm -f setup.sh /tmp/setup.log
