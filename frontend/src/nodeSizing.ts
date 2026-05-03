import type { RuntimeGraphNodeData } from "./types";

const MIN_NODE_WIDTH = 312;
const MAX_NODE_WIDTH = 620;
const CARD_PADDING = 24;
const GRID_GAP = 10;
const PORT_HORIZONTAL_PADDING = 26;
const MONO_CHAR_WIDTH = 8.1;

export function nodeWidth(node: RuntimeGraphNodeData) {
  const longestInput = longestPortName(node.inputs);
  const longestOutput = longestPortName(node.outputs);
  const inputWidth = portColumnWidth(longestInput);
  const outputWidth = portColumnWidth(longestOutput);
  return clamp(Math.ceil(CARD_PADDING + inputWidth + GRID_GAP + outputWidth), MIN_NODE_WIDTH, MAX_NODE_WIDTH);
}

function longestPortName(ports: RuntimeGraphNodeData["inputs"]) {
  return ports.reduce((longest, port) => Math.max(longest, port.name.length), 0);
}

function portColumnWidth(characters: number) {
  return Math.ceil(PORT_HORIZONTAL_PADDING + characters * MONO_CHAR_WIDTH);
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}
