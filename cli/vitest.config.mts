import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    testTimeout: 20000,
    // Hide flutter/pod/bundle on PATH so plans don't depend on the machine.
    env: { CLIKGATE_SETUP_NO_TOOLS: '1', CLIKGATE_NO_BROWSER: '1' },
  },
});
