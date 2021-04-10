FROM ubuntu:bionic AS builder
##########################################################
# Build clang, and then build libcxx/libcxx abi with gclang
# Having our own repo lets us pull from llvm mainstream ez
# It also debloats other codebases that use this
##########################################################

ARG BUILD_TYPE="Release"

# Build clang libs, cxx libs. Export the bin, and cxx libs?
RUN DEBIAN_FRONTEND=noninteractive apt-get -y update  \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git                                             \
      ninja-build                                     \
      wget                                            \
      python3.7-dev                                   \
      python3-distutils                               \
      golang                                          \
      clang-10

RUN wget https://github.com/Kitware/CMake/releases/download/v3.19.2/cmake-3.19.2-Linux-x86_64.sh
RUN mkdir -p /usr/bin/cmake-3.19
RUN chmod +x cmake-3.19.2-Linux-x86_64.sh && ./cmake-3.19.2-Linux-x86_64.sh --skip-license --prefix=/usr/bin/cmake-3.19
ENV PATH="/usr/bin/cmake-3.19/bin:${PATH}"
ENV LLVM_CXX_DIR=/polytracker-llvm/llvm

RUN go get github.com/SRI-CSL/gllvm/cmd/...
ENV PATH="$PATH:/root/go/bin"

COPY . /polytracker-llvm
ENV LLVM_DIR=/polytracker-llvm/llvm

RUN mkdir /cxx_libs && mkdir /polytracker_clang

WORKDIR /polytracker_clang
RUN cmake -GNinja ${LLVM_DIR} \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_ENABLE_PROJECTS="clang;llvm;compiler-rt" \
  -DCMAKE_BUILD_TYPE=${BUILD_TYPE}

RUN ninja install
ENV PATH="$PATH:/polytracker_clang/bin"
RUN clang --version
# Build two copies of cxx lib
ENV CXX_DIR=/cxx_libs
ENV LLVM_CXX_DIR=/polytracker-llvm/llvm
ENV CLEAN_CXX_DIR=$CXX_DIR/clean_build
ENV BITCODE=/cxx_clean_bitcode
ENV POLY_CXX_DIR=$CXX_DIR/poly_build
ENV CC="gclang"
ENV CXX="gclang++"

RUN mkdir -p $CXX_DIR
WORKDIR $CXX_DIR

RUN mkdir -p $CLEAN_CXX_DIR && mkdir -p $BITCODE
WORKDIR $CLEAN_CXX_DIR

RUN cmake -GNinja ${LLVM_CXX_DIR} \
  -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLIBCXXABI_ENABLE_SHARED=NO \
  -DLIBCXX_ENABLE_SHARED=NO \
  -DLIBCXX_CXX_ABI="libcxxabi" \
  -DLLVM_ENABLE_PROJECTS="libcxx;libcxxabi"

ENV WLLVM_BC_STORE=$BITCODE
RUN ninja cxx cxxabi

WORKDIR $CXX_DIR

ENV BITCODE=/cxx_poly_bitcode
RUN mkdir -p $POLY_CXX_DIR && mkdir -p $BITCODE

WORKDIR  $POLY_CXX_DIR

RUN cmake -GNinja ${LLVM_CXX_DIR} \
  -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLIBCXX_ABI_NAMESPACE="__p" \
  -DLIBCXXABI_ENABLE_SHARED=NO \
  -DLIBCXX_ENABLE_SHARED=NO \
  -DLIBCXX_ABI_VERSION=2 \
  -DLIBCXX_CXX_ABI="libcxxabi" \
  -DLIBCXX_HERMETIC_STATIC_LIBRARY=ON \
  -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
  -DLLVM_ENABLE_PROJECTS="libcxx;libcxxabi"

ENV WLLVM_BC_STORE=$BITCODE
RUN ninja cxx cxxabi

# We don't need the test directory, and it is large
RUN rm -rf /polytracker-llvm/llvm/test


FROM ubuntu:bionic AS polytracker-llvm
MAINTAINER Evan Sultanik <evan.sultanik@trailofbits.com>
MAINTAINER Carson Harmon <carson.harmon@trailofbits.com>

RUN DEBIAN_FRONTEND=noninteractive apt-get -y update  \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      cmake                                           \
      git                                             \
      golang

RUN go get github.com/SRI-CSL/gllvm/cmd/...

# Clang and LLVM binaries with our DFSan mods
COPY --from=builder /polytracker_clang /polytracker_clang
# Contains libcxx for target, and polytracker private libcxx
COPY --from=builder /cxx_libs /cxx_libs
# Contains gclang produced bitcode for libcxx. For libcxx instrumentation
COPY --from=builder /cxx_clean_bitcode /cxx_clean_bitcode
# Contains LLVM headers used to build polytracker
COPY --from=builder /polytracker-llvm/llvm /polytracker-llvm/llvm

WORKDIR /
RUN mkdir /build_artifacts

ENV DFSAN_LIB_PATH=/polytracker_clang/lib/clang/13.0.0/lib/linux/libclang_rt.dfsan-x86_64.a
ENV CXX_LIB_PATH=/cxx_libs
ENV WLLVM_BC_STORE=/cxx_clean_bitcode
ENV WLLVM_ARTIFACT_STORE=/build_artifacts
ENV POLYTRACKER_CAN_RUN_NATIVELY=1
ENV PATH="/polytracker_clang/bin:/root/go/bin:${PATH}"
