# once-campfire-verification

Shared verification and benchmarks for [Campfire](https://github.com/basecamp/once-campfire) and its Roda, Django, Laravel, Express, Elixir, Go, Rust, C and C++ implementations.

Every measured HTTP response must match its route contract: status, headers, complete decoded body, expected messages and content. Every acknowledged message write must match its exact persisted ID, body, room and search-index entry. Any invalid response or failed write audit fails the run. Browser flows check installation, live messages, editing, search, permissions, settings, invitations and session transfer.

See the [current results and verification report](docs/performance-review.md).
The [Rails/Roda comparison on an Apple M4 Mac mini with 10 cores](https://github.com/makevoid/once-campfire-roda/blob/main/docs/performance.md) records all production and mixed-workload rounds, source fingerprints and validation limits.

## Run

Requires Ruby with Minitest, Rust 1.98.1, Node 22.18+, SQLite CLI, FFmpeg, Git and Docker. Keep this checkout alongside the implementation checkouts.

```sh
npm ci
npx playwright install chromium
bin/check
bin/seed
cargo build --release --locked --manifest-path loadgen/Cargo.toml
bin/benchmark --apps rails,elixir,go,rust
```

Build the implementations' production images first. Override their image names with `RAILS_IMAGE`, `RODA_IMAGE`, `DJANGO_IMAGE`, `LARAVEL_IMAGE`, `EXPRESS_IMAGE`, `ELIXIR_IMAGE`, `GO_IMAGE`, `RUST_IMAGE`, `C_IMAGE` and `CPP_IMAGE`. The default comparison is **Rails versus Roda**, with three alternating eight-second rounds and 16 concurrent clients. Select other implementations explicitly with `--apps`. `--help` lists CPU affinity, seed path, route selection and output options. A process lock prevents overlapping benchmark runs. The fixture builder pins public Rails revision `90b3300` and generates real attachments and variants; it generates disposable signing, push and login credentials locally and refuses to overwrite an existing seed.

The default CPU sets are 0–3 for the server and 4–7 for the client, requiring at least eight available CPUs. Both Ruby servers explicitly enable YJIT. Source checkout locations can be overridden with variables such as `RAILS_SOURCE` and `RODA_SOURCE`. Receipts record source revisions, dirty state and runtime fingerprints; images carrying an `io.campfire.source.sha256` label must match their source checkout.

On macOS, use Homebrew's SQLite CLI and Docker Desktop with at least eight virtual CPUs. Build the containerized client from this repository:

```sh
docker build -f loadgen/Dockerfile -t campfire-verification:local .
```

The host orchestrator uses bridge networking on macOS and exposes the server only on host loopback. The client container shares the server's network namespace and mounts only its disposable fixture directory. `--client-image` (or `BENCH_CLIENT_IMAGE`) overrides the client image; `--network` overrides server networking. Linux defaults to the host Rust binary with `taskset` and host networking. Client CPU utilization is unavailable in container-client receipts.

Roda's benchmark image must import the shared Rails fixture into `/rails/storage/db/roda.sqlite3` and configure its normal production server and worker. The public [Roda preparation command](https://github.com/makevoid/once-campfire-roda/blob/main/bench/verification/README.md) builds that adapter. Read expectations still come from the common Rails fixture SQL; Roda writes are audited against its native schema. Both runtimes receive the same disabled placeholder authors for orphaned messages and loopback discard URLs for outbound fixture endpoints. Original seed data remains unchanged.

An optional cache-churn profile runs the same validated reads alongside one paced writer:

```sh
bin/benchmark --apps rails,elixir,go,rust --mixed-write-rate 10
```

It posts at most ten messages per second to a separate room, without catch-up bursts.
Warmup and timed writes use the same response and persisted-write audits as the normal
POST benchmark. Reader and writer measurements stay separate in `mixed-summary.json`;
they do not enter the headline table. This tests cache invalidation under writes, not
sustained chat capacity. See the [source architecture inventory](docs/architecture.md).

Against a **fresh, disposable** running app:

```sh
bin/browser --base http://127.0.0.1:3000
```

Allow several hundred megabytes of free space in `/tmp` for browser runs. Playwright's default `--disable-dev-shm-usage` makes Chromium use temporary files for shared memory; this harness sets `TMPDIR` under `/tmp`. Low space can cause asset loads to fail with `ERR_INSUFFICIENT_RESOURCES` even when RAM is available.

A dependency-free frontend regression can also check an implementation’s room-list controller:

```sh
node test/sidebar-reload.mjs ../once-campfire/app/javascript/controllers/rooms_list_controller.js
node test/editor-preservation.mjs ../once-campfire/app/javascript/controllers/rooms_list_controller.js
```

For frontends that negotiate JSON autocomplete responses:

```sh
node test/autocomplete-json.mjs ../once-campfire-elixir/assets/overrides/lib/autocomplete/base_autocomplete_handler.js
```

The browser flow creates and modifies accounts, rooms and messages. Run each implementation's own complete test suite as well: shared checks complement framework-specific tests and screenshot inventories.

The HTTP client sends Fetch Metadata for browser writes and includes legacy CSRF tokens only when an older implementation provides them.

`loadgen cable --sessions FILE --refresh-secs 50` exercises separate session subscriptions and staggered presence refreshes. Each line contains a cookie followed by tab-separated Action Cable identifiers; clients cycle through the rows. Generate sessions for independently verified fixture users when testing distinct people. Results report assigned rows, distinct cookie strings, subscription count ranges, unread notices and refreshes sent; cookie counts alone do not establish user counts. Refreshes start after presence subscription confirmation and skip missed ticks. This profile requires the ordinary WebSocket client; `--deflate` does not support refresh commands.

Raw results, seeds and browser artifacts stay in ignored directories. Raw benchmark receipts are not committed. An HTTP throughput result does not measure concurrent users or WebSocket capacity.

## Provenance

Extracted from the Rust and Elixir verification work, with browser flows adapted from the Go implementation. The fixtures are built by the public Rails app. Original 37signals copyright and MIT license are retained.
