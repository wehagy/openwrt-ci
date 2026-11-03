# Responsibility: derive the harness Image Builder image of a snapshot line
# from the official snapshot container (openwrt/imagebuilder). Snapshot
# containers ship only setup.sh, which downloads the Image Builder archive
# (hundreds of MB, 8 to 15 minutes on a slow mirror) at run time; running it
# here, once, moves that download out of every image job. The Image Builder
# of a release line needs no such step: the official release container has it
# (setup.sh already run, RUN_SETUP=1 in openwrt/docker), and the refresh
# mirrors that container as it is.
#
# Build (scripts/image-refresh.sh, the daily refresh; the context is this
# Dockerfile plus scripts/ib-setup.sh and scripts/lib/common.sh):
#   docker build --build-arg BASE=docker.io/openwrt/imagebuilder:<target>-<subtarget>-<line> <context>
#
# The line of /builder/.archive is the verified "<sha256> *<archive>" line
# printed by setup.sh; scripts/image-refresh.sh copies it into image labels.
# The sha256 of this file is an image label: a change here rebuilds the image.
#
# setup.sh runs through scripts/ib-setup.sh, which repeats it only when the
# archive does not match the sha256sums (see the Dockerfile of the SDK image).
# setup.sh is removed afterwards: the Image Builder is in the image and the
# image jobs download nothing.
ARG BASE
FROM ${BASE}

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

USER root
COPY --chmod=0755 ib-setup.sh /usr/local/lib/harness/ib-setup.sh
# 0755: --chmod also applies to the directories COPY creates, and the build user must traverse them
COPY --chmod=0755 lib/common.sh /usr/local/lib/harness/lib/common.sh
USER buildbot

RUN /usr/local/lib/harness/ib-setup.sh | tee /tmp/setup.log \
    && archive=$(grep -E '^[0-9a-f]{64} [*]' /tmp/setup.log | tail -n 1) \
    && [ -n "${archive}" ] \
    && printf '%s\n' "${archive}" > /builder/.archive \
    && rm -f setup.sh /tmp/setup.log
