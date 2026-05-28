# Dockerfile
# Extends NVIDIA's pre-built IsaacLab 2.3.2 image (Isaac Sim 5.1 + IsaacLab
# 2.3.2 already installed). We add only what leisaac needs for recording /
# teleop. lerobot is intentionally NOT installed here — training and
# evaluation are decoupled into a separate environment.
#
# Build on the GCP instance:
#   cd /workspace && docker build -t leisaac:latest .
#   docker build --no-cache -t leisaac:latest .   # clean rebuild
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

# pyzmq: needed for SO-101 remote teleop ZMQ pattern.
# grpcio/protobuf: needed for LeRobot policy server eval (test-9).
# Versions match leisaac's lerobot-async extra and the Dockerfile.train image.
RUN /isaac-sim/python.sh -m pip install pyzmq "grpcio==1.74.0" "protobuf==6.32.0"

# === Everything below re-runs when CACHEBUST changes (fresh fork clones). =====
ARG CACHEBUST=0


# Clone and install the leisaac fork against the bundled Python.
# LEISAAC_REPO / LEISAAC_BRANCH can be overridden via --build-arg.
ARG LEISAAC_REPO=https://github.com/krallistic/leisaac.git
ARG LEISAAC_BRANCH=
RUN git clone ${LEISAAC_REPO} /workspace/leisaac \
    && cd /workspace/leisaac \
    && if [ -n "${LEISAAC_BRANCH}" ]; then git checkout ${LEISAAC_BRANCH}; fi \
    && /isaac-sim/python.sh -m pip install -e source/leisaac

WORKDIR /workspace