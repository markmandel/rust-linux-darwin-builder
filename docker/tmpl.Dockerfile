# NOTE: Most of Dockerfile and related files were borrowed from
#       https://hub.docker.com/r/joseluisq/rust-linux-darwin-builder

FROM debian:$DEBIAN_TAG

LABEL maintainer="Jose Quintana <git.io/joseluisq>"

# The Rust toolchain to use when building our image. Set by `hooks/build`.
ARG TOOLCHAIN=stable

# The OpenSSL version to use. We parameterize this because many Rust
# projects will fail to build with 1.1.
ARG OPENSSL_VERSION=1.0.2r

# Make sure we have basic dev tools for building C libraries. Our goal
# here is to support the musl-libc builds and Cargo builds needed for a
# large selection of the most popular crates.
RUN set -eux \
	&& DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends --no-install-suggests \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        gcc-arm-linux-gnueabihf \
        git \
        libgmp-dev \
        libmpc-dev \
        libmpfr-dev \
        libpq-dev \
        libsqlite-dev \
        libssl-dev \
        libxml2-dev \
        linux-libc-dev \
        lzma-dev \
        musl-dev \
        musl-tools \
        nano \
        patch \
        pkgconf \
        python \
        sudo \
        xutils-dev \
        zlib1g-dev \
# We also set up a `rust` user by default, in whose account we'll install
# the Rust toolchain. This user has sudo privileges if you need to install
# any more software.
    && useradd rust --user-group --create-home --shell /bin/bash --groups sudo \
# `mdbook` is the standard Rust tool for making searchable HTML manuals.
    && MDBOOK_VERSION=0.2.1 && \
    curl -LO https://github.com/rust-lang-nursery/mdBook/releases/download/v$MDBOOK_VERSION/mdbook-v$MDBOOK_VERSION-x86_64-unknown-linux-musl.tar.gz && \
    tar xf mdbook-v$MDBOOK_VERSION-x86_64-unknown-linux-musl.tar.gz && \
    mv mdbook /usr/local/bin/ && \
    rm -f mdbook-v$MDBOOK_VERSION-x86_64-unknown-linux-musl.tar.gz \
# Clean up local repository of retrieved packages and remove the package lists
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Static linking for C++ code
RUN set -eux \
    && sudo ln -s "/usr/bin/g++" "/usr/bin/musl-g++"

# Allow sudo without a password.
ADD docker/sudoers /etc/sudoers.d/nopasswd

# Run all further code as user `rust`, and create our working directories
# as the appropriate user.
USER rust
RUN set -eux \
    && mkdir -p /home/rust/libs /home/rust/src

# Set up our path with all our binary directories, including those for the
# musl-gcc toolchain and for our Rust toolchain.
ENV PATH=/home/rust/.cargo/bin:/usr/local/musl/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Install our Rust toolchain and the `musl` target.  We patch the
# command-line we pass to the installer so that it won't attempt to
# interact with the user or fool around with TTYs.  We also set the default
# `--target` to musl so that our users don't need to keep overriding it
# manually.
RUN set -eux \
    && curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain $TOOLCHAIN \
    && rustup target add x86_64-unknown-linux-musl \
    && rustup target add armv7-unknown-linux-musleabihf \
    && rustup target add x86_64-apple-darwin
ADD docker/cargo-config.toml /home/rust/.cargo/config

# Set up a `git credentials` helper for using GH_USER and GH_TOKEN to access
# private repositories if desired.
ADD docker/git-credential-ghtoken /usr/local/bin
RUN set -eux \
    && git config --global credential.https://github.com.helper ghtoken

# Build a static library version of OpenSSL using musl-libc.  This is needed by
# the popular Rust `hyper` crate.
#
# We point /usr/local/musl/include/linux at some Linux kernel headers (not
# necessarily the right ones) in an effort to compile OpenSSL 1.1's "engine"
# component. It's possible that this will cause bizarre and terrible things to
# happen. There may be "sanitized" header
RUN set -eux \
    && echo "Building OpenSSL..." \
    && ls /usr/include/linux \
    && sudo mkdir -p /usr/local/musl/include \
    && sudo ln -s /usr/include/linux /usr/local/musl/include/linux \
    && sudo ln -s /usr/include/x86_64-linux-gnu/asm /usr/local/musl/include/asm \
    && sudo ln -s /usr/include/asm-generic /usr/local/musl/include/asm-generic \
    && cd /tmp \
    && curl -LO "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
    && tar xvzf "openssl-$OPENSSL_VERSION.tar.gz" && cd "openssl-$OPENSSL_VERSION" \
    && env CC=musl-gcc ./Configure no-shared no-zlib -fPIC --prefix=/usr/local/musl -DOPENSSL_NO_SECURE_MEMORY linux-x86_64 \
    && env C_INCLUDE_PATH=/usr/local/musl/include/ make depend \
    && env C_INCLUDE_PATH=/usr/local/musl/include/ make \
    && sudo make install \
    && sudo rm /usr/local/musl/include/linux /usr/local/musl/include/asm /usr/local/musl/include/asm-generic \
    && rm -r /tmp/*

RUN set -eux \
    && echo "Building zlib..." \
    && cd /tmp \
    && ZLIB_VERSION=1.2.11 \
    && curl -LO "http://zlib.net/zlib-$ZLIB_VERSION.tar.gz" \
    && tar xzf "zlib-$ZLIB_VERSION.tar.gz" \
    && cd "zlib-$ZLIB_VERSION" \
    && CC=musl-gcc ./configure --static --prefix=/usr/local/musl \
    && make \
    && sudo make install \
    && rm -r /tmp/*

RUN set -eux \
    && echo "Building libpq..." \
    && cd /tmp \
    && POSTGRESQL_VERSION=11.2 \
    && curl -LO "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.gz" \
    && tar xzf "postgresql-$POSTGRESQL_VERSION.tar.gz" \
    && cd "postgresql-$POSTGRESQL_VERSION" \
    && CC=musl-gcc CPPFLAGS=-I/usr/local/musl/include LDFLAGS=-L/usr/local/musl/lib ./configure --with-openssl --without-readline --prefix=/usr/local/musl \
    && cd src/interfaces/libpq \
    && make all-static-lib \
    && sudo make install-lib-static \
    && cd ../../bin/pg_config \
    && make \
    && sudo make install \
    && rm -r /tmp/*

ENV OPENSSL_DIR=/usr/local/musl/ \
    OPENSSL_INCLUDE_DIR=/usr/local/musl/include/ \
    DEP_OPENSSL_INCLUDE=/usr/local/musl/include/ \
    OPENSSL_LIB_DIR=/usr/local/musl/lib/ \
    OPENSSL_STATIC=1 \
    PQ_LIB_STATIC_X86_64_UNKNOWN_LINUX_MUSL=1 \
    PG_CONFIG_X86_64_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    LIBZ_SYS_STATIC=1 \
    TARGET=musl

# (Please feel free to submit pull requests for musl-libc builds of other C
# libraries needed by the most popular and common Rust crates, to avoid
# everybody needing to build them manually.)

ENV OSXCROSS_SDK_VERSION 10.11

RUN set -eux \
    && echo "Building osxcross..." \
    && cd /home/rust \
    && git clone --depth 1 https://github.com/tpoechtrager/osxcross \
    && cd osxcross \
    && curl -L -o ./tarballs/MacOSX${OSXCROSS_SDK_VERSION}.sdk.tar.xz \
    https://s3.amazonaws.com/andrew-osx-sdks/MacOSX${OSXCROSS_SDK_VERSION}.sdk.tar.xz \
    && env UNATTENDED=yes OSX_VERSION_MIN=10.7 ./build.sh \
    && rm -rf *~ taballs *.tar.xz \
    && rm -rf /tmp/*

ENV PATH $PATH:/home/rust/osxcross/target/bin

# Expect our source code to live in /home/rust/src.  We'll run the build as
# user `rust`, which will be uid 1000, gid 1000 outside the container.
WORKDIR /home/rust/src

CMD ["bash"]

# Metadata
LABEL org.opencontainers.image.vendor="Jose Quintana" \
    org.opencontainers.image.url="https://github.com/joseluisq/rust-linux-darwin-builder" \
    org.opencontainers.image.title="Rust Linux / Darwin Builder" \
    org.opencontainers.image.description="Use same Docker image for compiling Rust programs for Linux (musl libc) & macOS (osxcross)." \
    org.opencontainers.image.version="$VERSION" \
    org.opencontainers.image.documentation="https://github.com/joseluisq/rust-linux-darwin-builder"
