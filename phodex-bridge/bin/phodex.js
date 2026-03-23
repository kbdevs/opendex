#!/usr/bin/env node
// FILE: phodex.js
// Purpose: Backward-compatible wrapper that forwards legacy `phodex up` usage to `opendex up`.
// Layer: CLI binary
// Exports: none
// Depends on: ./opendex

require("./opendex");
