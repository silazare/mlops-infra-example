# triton-py — Triton Inference Server runtime + Python deps for the python-backend models
# (faster-whisper ASR, YOLO pre/post-processing) and Model Analyzer
#
# Model repository lives in S3 and is mounted at /models.
#
# Build (Argo Workflows image-build template):
#   argo submit -n argo --watch --from wftmpl/image-build \
#     -p image=triton-py -p tag=26.09-1 -p context=mlops/triton/image
FROM nvcr.io/nvidia/tritonserver:26.09-py3

ENV PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_NO_CACHE_DIR=1

# faster-whisper (CTranslate2). The CTranslate2 wheels are linked against CUDA 12 / cuDNN 9 while the
# image ships CUDA 13.4, so the cu12 runtime libraries come from pip (the faster-whisper docs recipe).
# They are NOT put on a global LD_LIBRARY_PATH: libcudnn.so.9 would shadow the image's CUDA 13 cuDNN
# used by the onnxruntime/tensorrt backends. The whisper model.py preloads them with ctypes instead.
RUN pip install \
      faster-whisper==1.2.1 \
      ctranslate2==4.8.3 \
      nvidia-cublas-cu12==12.9.2.10 \
      nvidia-cudnn-cu12==9.27.0.42

# Audio I/O and image pre/post-processing for the python-backend models (numpy 1.26.4 comes with the image)
RUN pip install \
      soundfile==0.14.0 \
      opencv-python-headless==4.14.0.94 \
      pillow==13.0.0

# Model Analyzer runs in this image in `local` launch mode (needs the tritonserver binary next to it)
RUN pip install triton-model-analyzer==1.58.0

# Model repository mount point (RWX PVC or S3-synced copy)
RUN mkdir -p /models
