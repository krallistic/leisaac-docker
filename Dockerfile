# Dockerfile
# Builds a LeIsaac-ready image with Isaac Sim 4.5, IsaacLab 2.1.0, and PyTorch.
# Layers are split intentionally to stay under GHCR's 10GB per-layer hard limit
# and 10 minute per-layer upload timeout.
#
# This image does NOT contain your forks of lerobot/leisaac. Those get cloned
# at runtime inside the instance via setup-instance.sh so you can iterate
# without rebuilding the image.
#
# Build size: ~21 GB total, largest single layer ~7 GB (Isaac Sim wheels).

# Base: CUDA 11.8 + cuDNN, Ubuntu 22.04. Smaller than nvcr.io/isaac-sim and
# all we need is CUDA + a place to pip-install isaacsim wheels.


FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# Layer 1: system deps (~200 MB)
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake build-essential git tmux wget curl ca-certificates \
        libxext6 libx11-6 libxrender1 libsm6 libglu1-mesa libxi6 libxrandr2 \
        libxinerama1 libxcursor1 libegl1 libgl1 libgomp1 \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Layer 2: miniforge (~500 MB)
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/m.sh && \
    bash /tmp/m.sh -b -p /opt/conda && rm /tmp/m.sh
ENV PATH=/opt/conda/bin:$PATH

# Layer 3: conda env with python (~1 GB)
RUN conda create -y -n leisaac python=3.10 && conda clean -ya
ENV CONDA_DEFAULT_ENV=leisaac
ENV PATH=/opt/conda/envs/leisaac/bin:$PATH

# Layer 4: PyTorch + cu118 (~5 GB)
RUN pip install --no-cache-dir \
        torch==2.5.1 torchvision==0.20.1 \
        --index-url https://download.pytorch.org/whl/cu118

# Layer 5: Isaac Sim 4.5.0 wheels (~7 GB)
# This is the biggest layer. Stays under both the 10 GB cap and 10 min upload
# timeout from a fast GHA runner.
RUN pip install --no-cache-dir 'isaacsim[all,extscache]==4.5.0' \
        --extra-index-url https://pypi.nvidia.com

# Layer 6: IsaacLab v2.1.0 (~2 GB)
RUN git clone -b v2.1.0 https://github.com/isaac-sim/IsaacLab.git /opt/IsaacLab && \
    cd /opt/IsaacLab && \
    pip install --no-cache-dir -e source/isaaclab && \
    pip install --no-cache-dir -e source/isaaclab_assets && \
    pip install --no-cache-dir -e source/isaaclab_tasks && \
    pip install --no-cache-dir -e source/isaaclab_rl && \
    pip install --no-cache-dir -e source/isaaclab_mimic

# Layer 7: smaller deps (~50 MB)
RUN pip install --no-cache-dir pyzmq

# Convenience: auto-activate the env on shell login
RUN echo "source /opt/conda/etc/profile.d/conda.sh && conda activate leisaac" >> /root/.bashrc

WORKDIR /workspace
ENV ACCEPT_EULA=Y PRIVACY_CONSENT=Y