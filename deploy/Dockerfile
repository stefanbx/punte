FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
# Keep in step with KUBO_V in relay/install-relay.sh — deploy.sh asserts they match and passes the
# installer's value, so a hosted node and a self-installed one never run different IPFS versions.
# They already had: this image sat on v0.29.0 while the installer pinned v0.43.0.
ARG KUBO_VERSION=v0.43.0
# From kubo's GitHub release, not dist.ipfs.tech: dist was down for the 2.5.14 deploy and a truncated
# download failed the build after 300 s. The SHA-512 is pinned HERE (not fetched next to the tarball),
# so a bumped KUBO_VERSION without a new hash fails the build instead of trusting whatever downloads.
# v0.43.0's hash matches kubo's published .sha512, and the binary inside is byte-identical to the one
# the node had been running from dist.ipfs.tech.
ARG KUBO_SHA512=6af21cd24a307d94326807b3d3827064c74fb7122f83b6940af250e6ae40da250e0ec0e1f3551256b78cd204623ed56c32ce735bbe28bdcc787b36943c52458a
RUN curl -fsSL --retry 3 -o /tmp/kubo.tgz \
        https://github.com/ipfs/kubo/releases/download/${KUBO_VERSION}/kubo_${KUBO_VERSION}_linux-amd64.tar.gz \
    && echo "${KUBO_SHA512}  /tmp/kubo.tgz" | sha512sum -c - \
    && tar -xzf /tmp/kubo.tgz -C /tmp && mv /tmp/kubo/ipfs /usr/local/bin/ipfs && rm -rf /tmp/kubo /tmp/kubo.tgz
RUN pip install --no-cache-dir nanopy pynacl
WORKDIR /app
COPY app/ /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# A comma-separated list: rpc() tries them in order and fails over, so one datacenter-blocked or
# throttled public RPC can't make every balance read 0. (Lead with the highest published limit.)
# IPFS_PATH is set by entrypoint.sh (onto the persistent volume), so it's intentionally not fixed here.
ENV XC_NANO_RPC=https://nanoslo.0x.no/proxy,https://rpc.nano.to,https://rainstorm.city/api,https://node.somenano.com/proxy XC_FUND_NEW=0
EXPOSE 8790
CMD ["/entrypoint.sh"]
