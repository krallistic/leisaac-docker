# Dockerfile
# Base: NVIDIA's official Isaac Sim image (requires NGC auth to pull).
# This avoids having to recreate Isaac Sim's Python env from scratch. The base
# already has Isaac Sim with its bundled Python at /isaac-sim/python.sh, with
# all of NVIDIA's preinstalled deps. We just install IsaacLab on top using
# its own installer.
#
# Image size: ~16 GB total (~14 GB base, ~2 GB additions).

FROM nvcr.io/nvidia/isaac-sim:4.5.0

ENV DEBIAN_FRONTEND=noninteractive
ENV ACCEPT_EULA=Y
ENV PRIVACY_CONSENT=Y

# System tools we add on top of the base
RUN apt-get update && apt-get install -y --no-install-recommends \
        git tmux wget curl ca-certificates cmake build-essential \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Clone and install IsaacLab using its own installer.
# The installer uses /isaac-sim/python.sh (the bundled Python) and handles
# version pinning, dep ordering, and all the awkward bits we were trying
# to do manually.
RUN git clone -b v2.1.0 https://github.com/isaac-sim/IsaacLab.git /isaaclab && \
    cd /isaaclab && \
    ln -s /isaac-sim _isaac_sim && \
    ./isaaclab.sh --install

# Extra deps for the remote teleop ZMQ tunnel
RUN /isaac-sim/python.sh -m pip install pyzmq

# Convenience: in interactive shells, 'python' and 'pip' point to Isaac Sim's
# bundled tools. lerobot/leisaac will install against the same Python.
RUN echo 'alias python="/isaac-sim/python.sh"' >> /root/.bashrc && \
    echo 'alias pip="/isaac-sim/python.sh -m pip"' >> /root/.bashrc

WORKDIR /workspace