FROM nvidia/cuda:12.6.1-devel-ubuntu22.04

ENV CUDA_HOME=/usr/local/cuda

ARG TESSERACT_VERSION="main"
ARG TESSERACT_URL="https://api.github.com/repos/tesseract-ocr/tesseract/tarball/${TESSERACT_VERSION}"

# System Dependencies - Core Tools
RUN apt update && apt install -y \
    curl \
    wget \
    ca-certificates \
    apt-transport-https \
    unzip \
    zip \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# System Dependencies - Development Tools
RUN apt update && apt install -y \
    g++ \
    make \
    libtool \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# System Dependencies - Node.js and Python
RUN apt update && apt install -y \
    nodejs \
    npm \
    python3.10 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# System Dependencies - Tesseract Dependencies
RUN apt update && apt install -y \
    libleptonica-dev \
    && rm -rf /var/lib/apt/lists/*

# Build and Install Tesseract OCR
WORKDIR /src
RUN wget -qO tesseract.tar.gz $TESSERACT_URL \
    && tar -xzf tesseract.tar.gz \
    && mv tesseract-* tesseract

WORKDIR /src/tesseract
RUN ./autogen.sh \
    && ./configure \
    && make \
    && make install \
    && ldconfig

# Clean up tesseract build
RUN rm -rf /src

# Install Tesseract Language Data
WORKDIR /usr/local/share/tessdata/
COPY ./tesseract/get-languages.sh .
COPY ./tesseract/languages.txt .
RUN chmod +x ./get-languages.sh \
    && ./get-languages.sh \
    && rm ./get-languages.sh \
    && rm ./languages.txt

# System Cleanup
RUN rm -rf /var/cache/apk/* \
    && apt-get autoremove -y \
    && apt-get clean

# Python Package Management Setup
RUN python3 -m pip install --upgrade pip wheel

# JupyterLab Core Installation
RUN pip install jupyterlab==4.2.5 \
    && pip install ipywidgets==8.1.5 \
    && pip install jupyter_contrib_nbextensions==0.7.0 \
    && jupyter labextension enable @jupyterlab/toc

# Deep Learning Frameworks
RUN pip3 install torch==2.6.0 --index-url https://download.pytorch.org/whl/cu126 \
    && pip3 install tensorflow==2.17.0 \
    && pip3 install datasets==3.0.0

# Hugging Face Ecosystem
RUN pip3 install git+https://github.com/huggingface/transformers@919220dab1e29f4d04eacd61a197a45a4fec2613 \
    && pip3 install diffusers==0.30.0 \
    && pip3 install accelerate==0.34.2 \
    && pip3 install bitsandbytes==0.46.1

# Flash Attention is a memory-efficient attention mechanism for transformer models
# 1) Reduces memory usage
# 2) Improves speed
# 3) Enables larger models
# RUN pip3 install flash-attn --no-build-isolation
# RUN pip3 install flash-attn==2.7.4.post1 --no-build-isolation

RUN pip3 install git+https://github.com/huggingface/peft.git

# Vector Database
RUN pip3 install lancedb==0.13.0

# Information Retrieval and RAG Components
RUN pip3 install ir-measures==0.3.3 \
    && pip3 install rank-bm25==0.2.2 \
    && pip3 install RAGatouille==0.0.8.post4 \
    && pip3 install gliner==0.2.11

# Rerankers is a package for document reranking in RAG (Retrieval-Augmented Generation) pipelines
# 1) Document reranking: Reorders retrieved documents by relevance
# 2) Improves RAG quality: Better document selection for LLM context
# 3) Multiple backends: Supports various reranking models and APIs
# RUN pip3 install rerankers[all]==0.5.3

# NLP and Text Processing
RUN pip3 install nltk==3.9.1 \
    && pip3 install sentence_transformers==2.5.1

# Document Processing
RUN pip3 install pypdf==4.3.1 \
    && pip3 install openparse==0.7.0

# Embedding and Ranking Models
RUN pip3 install fastembed==0.3.3 \
    && pip3 install flashrank==0.2.8

# LangChain Ecosystem
RUN pip3 install langchain-community==0.2.6 \
    && pip3 install langchain-experimental==0.0.62 \
    && pip3 install langchain-groq==0.1.6 \
    && pip3 install langchain-qdrant==0.1.1 \
    && pip3 install langchain==0.2.6 \
    && pip3 install langchain-mistralai==0.1.12


RUN pip3 install lancedb==0.16.0 \
    && pip3 install git+https://github.com/huggingface/huggingface_hub@3618a38f80ae3073b95ea0fba26f363d2ec4ece8 \
    && pip3 install mangoCR==0.1.4


EXPOSE 8888
WORKDIR /jupyterlab

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.root_dir='/jupyterlab/notebooks'", "--allow-root"]
