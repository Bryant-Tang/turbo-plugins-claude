#!/usr/bin/env bash
# Usage: merge-settings-env.sh <path-to-settings.local.json> <json-blob-of-env-pairs>
# Merges key/value pairs from <json-blob> into the `env` block of <settings-file>.
# Creates the file (and parent .claude/ directory) if absent.
# Exits 1 with a stderr message if the existing file is not valid JSON.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: merge-settings-env.sh <settings-file> <env-json>" >&2
  exit 1
fi

SETTINGS_FILE="$1"
ENV_JSON="$2"

mkdir -p "$(dirname "$SETTINGS_FILE")"

node - "$SETTINGS_FILE" "$ENV_JSON" <<'EOF'
const fs = require('fs');
const [,, settingsPath, envJson] = process.argv;

let incoming;
try { incoming = JSON.parse(envJson); }
catch (e) { process.stderr.write('Error: invalid env JSON: ' + e.message + '\n'); process.exit(1); }

let existing = {};
if (fs.existsSync(settingsPath) && fs.statSync(settingsPath).size > 0) {
  try { existing = JSON.parse(fs.readFileSync(settingsPath, 'utf8').replace(/^﻿/, '')); }
  catch (e) { process.stderr.write('Error: ' + settingsPath + ' is not valid JSON: ' + e.message + '\n'); process.exit(1); }
}

if (!existing.env || typeof existing.env !== 'object') existing.env = {};
Object.assign(existing.env, incoming);

const tmp = settingsPath + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(existing, null, 2) + '\n', 'utf8');
fs.renameSync(tmp, settingsPath);
EOF
