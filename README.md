# Theia

### Shape worlds. Build them node by node.

Theia is a native terrain studio for macOS. It turns procedural ideas into
landscapes through a visual node graph—generate mountains, carve rivers, shape
slopes, inspect terrain data, and export the result for your engine.

Built for Apple Silicon and powered by Metal, Theia keeps terrain creation fast,
interactive, and entirely on your Mac.

> **Theia is currently in alpha.** The editor and core workflow are usable, but
> project files and features may continue to evolve.

## Create landscapes, not pipelines

Theia brings the essential terrain workflow into one focused tool:

- **Build with nodes** — combine generators, filters, erosion, rivers, masks,
  and transforms without locking your terrain into a single recipe.
- **Shape with natural processes** — use hydraulic, thermal, droplet, and
  fluvial erosion to create landforms with believable structure.
- **See every output** — preview terrain, masks, analysis data, normals, slopes,
  and shaded surfaces in the 3D viewport.
- **Export clean assets** — write 16-bit heightmaps, RAW terrain data, PFM
  fields, and OBJ meshes.

```text
Build a graph  →  Shape the terrain  →  Preview the world  →  Export
```

## Start creating

Theia requires macOS 14 or newer, Apple Silicon, and the Swift 6 toolchain.
Command Line Tools are enough; full Xcode is not required.

```sh
# Build Theia
swift build

# Open the node editor with an example landscape
swift run theia-viewer examples/showcase.json
```

Or generate terrain without opening the editor:

```sh
swift run theia-cli run examples/showcase.json \
  --size 1024 \
  --out terrain.png
```

## Explore the examples

The [`examples`](examples) directory includes ready-made graphs for:

- foundational terrain generation
- hydraulic and thermal erosion
- particle hydrology and river carving
- fluvial landscape evolution
- masks and typed analysis outputs

They are the fastest way to learn how Theia's nodes work together.

## Made for an open workflow

Theia separates the terrain engine from its tools:

- **TheiaCore** is the C++ graph and simulation engine.
- **theia-viewer** is the native visual editor and 3D viewport.
- **theia-cli** brings the same graph evaluation and export workflow to scripts
  and build pipelines.

Graphs are stored as readable JSON, so they can be versioned, inspected, and
generated outside the editor. The same graph produces the same result in the
viewer, CLI, and export pipeline.

For implementation details, see the
[architecture overview](docs/architecture.md). Physically or mathematically
based features are documented in the [research notes](docs/research/README.md).

## Useful commands

```sh
# Check your local setup
swift run theia-cli doctor

# Discover available nodes
swift run theia-cli nodes

# Validate a graph
swift run theia-cli diagnose examples/showcase.json

# Run the regression suite
swift run theia-tests
```

## Project status

Current release: **0.12.0-alpha.1**

Theia already supports a complete procedural terrain loop: node authoring,
GPU-backed generation, erosion and river systems, typed multi-output fields,
mask editing, 3D preview, and engine-ready export.

The next horizon is broader biome workflows and new physically informed
simulations.

## License

Theia is available under the [MIT License](LICENSE).

The experimental erosion-filter Metal kernel is available under MPL-2.0.
Third-party attribution and license details are listed in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
