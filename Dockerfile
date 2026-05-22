# Dockerfile
# Extends NVIDIA's pre-built IsaacLab 2.3.2 image.
# Isaac Sim 5.1 + IsaacLab 2.3.2 are already installed and tested inside.
# We only add what's specific to leisaac:
#   - pyzmq for remote teleop
#   - clone leisaac + install it against /isaac-sim/python.sh
#
# Build on the GCP instance (not pre-built/pushed anywhere):
#   cd /workspace && docker build -t leisaac:latest .
#
# NOTE: Assets (USD scenes) are mounted from the host at runtime, not baked in.
# Download them once with setup-instance.sh; they persist across container runs.

FROM nvcr.io/nvidia/isaac-lab:2.3.2

ENV DEBIAN_FRONTEND=noninteractive
ENV ACCEPT_EULA=Y
ENV PRIVACY_CONSENT=Y

RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux git \
    && rm -rf /var/lib/apt/lists/*

# pyzmq: needed for SO-101 remote teleop ZMQ pattern
RUN /isaac-sim/python.sh -m pip install pyzmq

# Clone and install leisaac against the bundled Python
# LEISAAC_REPO / LEISAAC_BRANCH can be overridden via --build-arg
ARG LEISAAC_REPO=https://github.com/LightwheelAI/leisaac.git
ARG LEISAAC_BRANCH=
RUN git clone ${LEISAAC_REPO} /workspace/leisaac \
    && cd /workspace/leisaac \
    && if [ -n "${LEISAAC_BRANCH}" ]; then git checkout ${LEISAAC_BRANCH}; fi \
    && /isaac-sim/python.sh -m pip install -e source/leisaac

WORKDIR /workspace