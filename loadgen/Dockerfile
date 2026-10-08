FROM rust:1.94-slim AS loadgen
WORKDIR /build
COPY loadgen/Cargo.toml loadgen/Cargo.lock ./
COPY loadgen/src ./src
RUN cargo build --release --locked

FROM ruby:4.0.7-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=loadgen /build/target/release/loadgen /usr/local/bin/loadgen
ENV LOADGEN=/usr/local/bin/loadgen
ENTRYPOINT ["/usr/local/bin/loadgen"]
