<div id="top"></div>

<img src="https://i.imgur.com/4FlvRAt.png" width="200">

# DeroGold

<summary>Table of Contents</summary>
<ol>
  <li><a href="#development-resources">Development Resources</a></li>
  <li><a href="#introduction">Introduction</a></li>
  <li><a href="#installing">Installing</a></li>
  <li><a href="#build-instructions">Build Instructions</a></li>
  <ol>
    <li><a href="BUILDING.md">Full build guide (all platforms)</a></li>
  </ol>
  <li><a href="#docker">Docker</a></li>
  <li><a href="#pruned-node-mode">Pruned Node Mode</a></li>
  <li><a href="#fast-sync---sync-from-height">Fast Sync (--sync-from-height)</a></li>
  <li><a href="#license">License</a></li>
  <li><a href="#thanks">Thanks</a></li>
</ol>

## Development Resources

* Web: https://derogold.com/
* GitHub: https://github.com/derogold/derogold-core
* Discord: https://discordapp.com/invite/j2aSNFn

<p align="right">(<a href="#top">back to top</a>)</p>

## Introduction

DeroGold is a digital assets project focused on preserving our life environment here on Earth.

DeroGold aspires to solve problems such as circular economy in recycling, re-use of waste materials and how we can drive positive behaviour by rewarding people with digital assets for recycling. And build habitable floating islands.

For simplicity, we say we are the digital "Nectar Card for Recycling".

However, we are much more than that. We run our own privacy digital asset that allows people and organisations to send and receive our native digital coins called DEGO.

<p align="right">(<a href="#top">back to top</a>)</p>

## Installing

We offer binary images of the latest releases here: https://github.com/derogold/derogold-core/releases

If you would like to compile yourself, read on.

<p align="right">(<a href="#top">back to top</a>)</p>


## Build Instructions

No package manager and no submodules. Install a compiler, CMake and three
libraries from your own distribution, then build:

```sh
# Debian / Ubuntu
sudo apt install build-essential cmake ninja-build git curl pkg-config \
    libboost-serialization-dev libssl-dev libzstd-dev

git clone -b development https://github.com/derogold/derogold-core.git
cd derogold-core
cmake -G Ninja -D CMAKE_BUILD_TYPE=Release -S . -B build
cmake --build build
```

Binaries land in `build/src`.

RocksDB is compiled from the copy in `external/`, because the version most
distributions package is older than this code needs. Nothing is downloaded
during the build, but it does make the first build noticeably longer. Pass
`-D DEROGOLD_SYSTEM_ROCKSDB=ON` to link your own copy instead, provided it is
8.1 or newer.

By default the build targets the machine it is compiled on. Pass
`-D ARCH=default` for binaries that run on other machines, at some cost in
performance.

See **[BUILDING.md](BUILDING.md)** for install commands on Fedora, Arch, macOS
and MSYS2, the CMake presets, RocksDB options, and notes on MSVC.

<p align="right">(<a href="#top">back to top</a>)</p>



## Docker

### Using the pre-built image

Pre-built images are published to the GitHub Container Registry on every release:

```bash
docker pull ghcr.io/derogold/derogold-core:latest
```

Run it straight away:

```bash
docker run -d \
    --name derogoldd \
    -p 42069:42069 \
    -p 6969:6969 \
    -v derogold-data:/data \
    ghcr.io/derogold/derogold-core:latest
```

Available tags: `latest`, `v1.0.1.0`, etc.

---

### Building your own image

If you prefer to build the image yourself from source, a `Dockerfile` is included in the repository.

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running

### Build the image

```bash
docker build -t derogoldd:latest .
```

### Run the container

**Standard node:**
```bash
docker run -d \
    --name derogoldd \
    -p 42069:42069 \
    -p 6969:6969 \
    -v derogold-data:/data \
    derogoldd:latest
```

**Fast sync from height 2,700,000:**
```bash
docker run -d \
    --name derogoldd \
    -p 42069:42069 \
    -p 6969:6969 \
    -v derogold-data:/data \
    derogoldd:latest --sync-from-height=2700000
```

**Pruned node:**
```bash
docker run -d \
    --name derogoldd \
    -p 42069:42069 \
    -p 6969:6969 \
    -v derogold-data:/data \
    derogoldd:latest --prune
```

### Useful commands

```bash
# View logs
docker logs -f derogoldd

# Access the daemon console
docker exec -it derogoldd DeroGoldd --help

# Stop the node
docker stop derogoldd

# Remove the container (data volume is preserved)
docker rm derogoldd
```

> **Note:** The blockchain data is stored in the `derogold-data` Docker volume and persists across container restarts and removals. To start fresh, remove the volume with `docker volume rm derogold-data`.

<p align="right">(<a href="#top">back to top</a>)</p>

## Pruned Node Mode

A pruned node retains only a recent window of raw block data, discarding historical blocks that are no longer needed for normal operation. This dramatically reduces disk usage while keeping the node fully functional for wallets and the network.

### Flags

| Flag | Default | Description |
|---|---|---|
| `--prune` | off | Enable pruned-node mode |
| `--prune-depth=<blocks>` | 2016 | Number of recent blocks to keep (minimum 2016 ≈ 7 days) |
| `--background-prune` | on | Run the prune task periodically in the background |

With a 5-minute block target, 2016 blocks ≈ 7 days of history. Increase `--prune-depth` if you need to serve more history to wallets.

### Usage

```bash
# Pruned node keeping the last 7 days of blocks (default depth)
./DeroGoldd --prune

# Pruned node keeping the last 30 days of blocks (~8640 blocks)
./DeroGoldd --prune --prune-depth=8640

# Disable the automatic background prune task (manual control only)
./DeroGoldd --prune --background-prune=false
```

> **Note:** `--prune` must be used on a fresh data directory or combined with `--resync`. It cannot be applied to an existing fully-synced database mid-run.

### Daemon console commands

Once the node is running, use these commands from the daemon console:

| Command | Description |
|---|---|
| `prune_status` | Show prune mode, depth, and current prune floor height |
| `compact_db [start\|status\|wait\|stop]` | Manually manage RocksDB compaction |
| `db_status` | Show database size and file statistics |

RocksDB compaction is also triggered **automatically** by a background scheduler. The scheduler runs every 60 seconds while the node is syncing, and slows to every 30 minutes once the node is near the chain tip.

<p align="right">(<a href="#top">back to top</a>)</p>

## Fast Sync (--sync-from-height)

The DeroGold blockchain is 350 GB+ from genesis. The `--sync-from-height` flag lets a fresh node skip the historical chain and start syncing from a recent checkpoint instead, reducing initial sync time from days to hours.

### How it works

On first launch with an empty database, the node injects a trusted anchor block at the specified height (verified against the hard-coded checkpoints) and begins downloading only blocks from that point onward. Blocks below the sync floor are trusted via the checkpoint — ring signature verification is bypassed for historical inputs that predate the floor, identically to how the standard checkpoint zone works.

> **Note:** Do not use `--sync-from-height` on mining nodes. Miners must have the full chain to correctly validate all outputs.

### Available sync floors

| Height    | Approx. date  |
|-----------|---------------|
| 2,700,000 | 2024          |

### Usage

```bash
./DeroGoldd --sync-from-height=2700000
```

The argument must match a supported height listed above. If the database already contains blocks the flag is silently ignored — use `--resync` first if you need a clean start.

### Exporting a new bootstrap state (for node operators)

If you run a fully-synced node and want to add a new floor height, run this command from the daemon console:

```
export_bootstrap_state <height>
```

The height must already exist in `CryptoNoteCheckpoints.h`. Copy the printed values into a new entry in `src/config/SyncBootstrapCheckpoints.h`, rebuild, and distribute.

<p align="right">(<a href="#top">back to top</a>)</p>

## License

Read the [LICENSE](https://github.com/derogold/derogold-core/blob/master/LICENSE) file for more details.

<p align="right">(<a href="#top">back to top</a>)</p>

## Thanks

Cryptonote Developers, Bytecoin Developers, Monero Developers, Forknote Project, TurtleCoin Developers, WRKZCoin Developers

<p align="right">(<a href="#top">back to top</a>)</p>
