FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ffmpeg + join_logo_scp ビルド依存パッケージ
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    bc \
    curl \
    jq \
    build-essential \
    git \
    cmake \
    ninja-build \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libboost-filesystem-dev \
    libboost-program-options-dev \
    libboost-system-dev \
    zlib1g-dev \
    libavformat-dev \
    libavcodec-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# AviSynthPlus（公式ソース）をビルドしてlogoframe用のヘッダ/共有ライブラリを入れる
RUN git clone --depth 1 --branch v3.7.5 \
        https://github.com/AviSynth/AviSynthPlus.git /opt/avisynthplus && \
    cmake -S /opt/avisynthplus -B /tmp/avisynthplus-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_PLUGINS=OFF \
        -DENABLE_INTEL_SIMD=OFF && \
    cmake --build /tmp/avisynthplus-build && \
    cmake --install /tmp/avisynthplus-build && \
    ldconfig && \
    rm -rf /opt/avisynthplus /tmp/avisynthplus-build

# FFMS2（公式ソース）をAviSynth入力プラグインとしてビルド
RUN git clone --depth 1 --branch 5.0 https://github.com/FFMS/ffms2.git /opt/ffms2 && \
    cd /opt/ffms2 && \
    ./autogen.sh && \
    ./configure --enable-avisynth \
        CPPFLAGS="-I/usr/local/include/avisynth" && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig && \
    rm -rf /opt/ffms2

# delogo-AviSynthPlus-Linux（ロゴ消しプラグイン）のビルド
RUN git clone --depth 1 \
        https://github.com/tobitti0/delogo-AviSynthPlus-Linux.git /opt/delogo && \
    cd /opt/delogo/src && \
    make && \
    mkdir -p /usr/local/lib/avisynth && \
    make install && \
    ldconfig && \
    rm -rf /opt/delogo

# join_logo_scp (tobitti0版) のビルド
RUN git clone --recursive --depth 1 --shallow-submodules \
        https://github.com/tobitti0/JoinLogoScpTrialSetLinux.git /opt/jls && \
    make -C /opt/jls/modules/chapter_exe/src && \
    make -C /opt/jls/modules/logoframe/src && \
    make -C /opt/jls/modules/join_logo_scp/src && \
    cp /opt/jls/modules/chapter_exe/src/chapter_exe /usr/local/bin/chapter_exe && \
    cp /opt/jls/modules/logoframe/src/logoframe /usr/local/bin/logoframe && \
    cp /opt/jls/modules/join_logo_scp/src/join_logo_scp /usr/local/bin/join_logo_scp

COPY scripts/tools/avs2y4m.cpp /tmp/avs2y4m.cpp
RUN gcc -O2 -Wall -Wextra -xc++ -o /usr/local/bin/avs2y4m /tmp/avs2y4m.cpp \
        -I/usr/local/include/avisynth -ldl -pthread -lstdc++ && \
    rm -f /tmp/avs2y4m.cpp && \
    ldconfig

ENV JLS_DIR="/opt/jls"

ENTRYPOINT ["/scripts/app/convert.sh"]
