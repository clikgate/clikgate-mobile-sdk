import { defineConfig } from 'tsup';

// One self-contained file: every dependency is bundled, so `npx @clikgate/setup` installs nothing else.
export default defineConfig({
  entry: { cli: 'src/index.ts' },
  format: ['cjs'],
  outExtension: () => ({ js: '.cjs' }),
  platform: 'node',
  target: 'node18',
  bundle: true,
  noExternal: [/.*/],
  minify: false,
  sourcemap: false,
  clean: true,
  splitting: false,
  banner: { js: '#!/usr/bin/env node' },
});
