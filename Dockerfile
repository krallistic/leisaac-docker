# Dockerfile
# Base: NVIDIA's pre-built IsaacLab 2.3.2 container.
# Contains Isaac Sim 5.1, IsaacLab 2.3.2, and Omniverse runtime, all already
# installed and tested by NVIDIA. We just add what's specific to our setup:
#   - pyzmq for remote teleop
#   - convenience shell aliases
#
# IsaacLab source is at /workspace/IsaacLab (already pip-installed).
# Isaac Sim's bundled Python is at /isaac-sim/python.sh (now Python 3.11).
#
# This image targets CUDA 13 / driver 580+, which matches current Vast.ai
# datacenter supply. If you need to roll back to Isaac Sim 4.5, swap the
# FROM to nvcr.io/nvidia/isaac-lab:2.1.0 and pin Vast hosts to CUDA 12.x.
#
# NOTE: NVIDIA describes this image as "headless only, no X11". WebRTC
# livestreaming still works because it's network-based, not X-based.

FROM nvcr.io/nvidia/isaac-lab:2.3.2

ENV DEBIAN_FRONTEND=noninteractive
ENV ACCEPT_EULA=Y
ENV PRIVACY_CONSENT=Y

# Utilities not in the minimal NVIDIA base. Most dev tools (git, curl, etc.)
# are already present.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Only addition needed for our remote teleop ZMQ pattern.
# Isaac Sim 5.x bundles Python 3.11; pyzmq has wheels for it.
RUN /isaac-sim/python.sh -m pip install pyzmq

# Convenience: 'python' and 'pip' in interactive shells point at the bundled
# tools, so lerobot/leisaac install against the same Python as IsaacLab.
RUN echo 'alias python="/isaac-sim/python.sh"' >> /root/.bashrc && \
    echo 'alias pip="/isaac-sim/python.sh -m pip"' >> /root/.bashrc

WORKDIR /workspace