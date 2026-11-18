import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';

// Retain complete redistribution notices in the signed app's bundled copy.
const notices = await readFile(new URL('../ThirdParty/Recovery-NOTICES.txt', import.meta.url), 'utf8');
await build({
  entryPoints: ['recovery.js'],
  bundle: true,
  target: 'safari17',
  platform: 'browser',
  format: 'iife',
  globalName: 'LegacyRecovery',
  legalComments: 'inline',
  banner: { js: '/*\n' + notices.replaceAll('*/', '* /') + '\n*/' },
  outfile: '../Resources/legacy-recovery.js'
});
