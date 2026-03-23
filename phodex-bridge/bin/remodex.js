#!/usr/bin/env node
// FILE: remodex.js
// Purpose: Backward-compatible wrapper that forwards legacy `remodex` usage to `opendex`.
// Layer: CLI binary
// Exports: none
// Depends on: ./opendex

require("./opendex");
