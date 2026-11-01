// Run after format_fixtures.dart. Khronos validator executes locally on QA files.
const fs = require('node:fs');
const path = require('node:path');
const validator = require('../.tools/validators/node_modules/gltf-validator');
(async () => {
  const folder = process.argv[2];
  if (!folder) throw new Error('Pass the QA fixture directory.');
  let failed = false;
  for (const name of fs.readdirSync(folder).filter(n => /\.(glb|gltf)$/.test(n))) {
    const result = await validator.validateBytes(new Uint8Array(fs.readFileSync(path.join(folder, name))), { uri: name });
    const summary = { file: name, errors: result.issues.numErrors, warnings: result.issues.numWarnings, messages: result.issues.messages };
    console.log(JSON.stringify(summary));
    failed ||= summary.errors > 0;
  }
  if (failed) process.exitCode = 1;
})().catch(e => { console.error(e.message); process.exitCode = 1; });
