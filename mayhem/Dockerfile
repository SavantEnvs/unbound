# syntax=docker/dockerfile:1.7
#
# unbound commit-image (small form): FROM the org C/C++ base (dev image: full toolchain + source +
# .git retained). Builds via mayhem/build.sh: 5 libFuzzer harnesses over unbound's DNS wire-format
# packet parser/scrubber/sldns wire<->text converters (OSS-Fuzz parity — google/oss-fuzz/projects/
# unbound ships the same 5 targets), plus unbound's own unit-test binary as the test.sh oracle.
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV.
ARG SOURCE_DATE_EPOCH
# Sanitizer override (default = base ASan+UBSan, halting): --build-arg SANITIZER_FLAGS="...".
ARG SANITIZER_FLAGS
# Build parallelism (optional; build.sh falls back to nproc): --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# unbound's configure.ac unconditionally requires libexpat (expat.h) — not in the base image's
# default package set. Install as root before the mayhem user's build (baked into the image layer,
# so the offline PATCH-tier re-run of mayhem/build.sh never needs the network for this).
USER root
RUN apt-get update -qq && apt-get install -yq --no-install-recommends libexpat1-dev \
 && rm -rf /var/lib/apt/lists/*

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run unbound's own unit-test suite at build time — a failing suite fails the image build, so the
# commit image is guaranteed to build AND pass its own tests.
RUN bash mayhem/test.sh

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
