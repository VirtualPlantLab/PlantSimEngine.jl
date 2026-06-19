# PlantSimEngine Dependency Graph Viewer

This is the React Flow frontend for the PlantSimEngine dependency graph viewer.
It consumes the JSON emitted by `PlantSimEngine.graph_view_json`.

## Development

```sh
npm install
npm run dev
```

The app falls back to a small sample graph when no embedded
`<script id="pse-graph-data" type="application/json">` payload is present.

## Build

```sh
npm run build
```

The Julia package does not require Node, npm, or Bun for the standalone HTML
export path. JavaScript tooling is only needed when developing or bundling this
frontend.
