# Dockerfile
# Base: NVIDIA's pre-built IsaacLab container.
# Contains Isaac Sim, IsaacLab 2.1.0, and Omniverse runtime, all already
# installed and tested by NVIDIA. We just add what's specific to our setup:
#   - pyzmq for remote teleop
#   - convenience shell aliases
#
# IsaacLab source is at /workspace/IsaacLab (already pip-installed).
# Isaac Sim's bundled Python is at /isaac-sim/python.sh.
#
# NOTE: NVIDIA describes this image as "headless only, no X11". WebRTC
# livestreaming still works because it's network-based, not X-based. If
# you ever need a GUI desktop session, you'd swap this base for
# nvcr.io/nvidia/isaac-sim:4.5.0 and rebuild IsaacLab manually.

FROM nvcr.io/nvidia/isaac-lab:2.1.0

ENV DEBIAN_FRONTEND=noninteractive
ENV ACCEPT_EULA=Y
ENV PRIVACY_CONSENT=Y

# A couple of utilities for working inside the container that aren't in the
# minimal NVIDIA base. Most dev tools (git, curl, etc.) are already present.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Only addition needed for our remote teleop ZMQ pattern
RUN /isaac-sim/python.sh -m pip install pyzmq

# Convenience: 'python' and 'pip' in interactive shells point at the bundled
# tools, so lerobot/leisaac install against the same Python as IsaacLab.
RUN echo 'alias python="/isaac-sim/python.sh"' >> /root/.bashrc && \
    echo 'alias pip="/isaac-sim/python.sh -m pip"' >> /root/.bashrc

WORKDIR /workspace