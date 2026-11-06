const path = require('path');
const { getConfig } = require('react-native-builder-bob/babel-config');
const pkg = require('../package.json');

const root = path.resolve(__dirname, '..');

module.exports = getConfig(
  {
    presets: ['module:@react-native/babel-preset'],
    plugins: [
      // CLIKGATE_* environment variables are inlined at bundle time (see src/config.ts).
      // Restart Metro with --reset-cache after changing them.
      [
        'transform-inline-environment-variables',
        {
          include: [
            'CLIKGATE_SDK_KEY',
            'CLIKGATE_API_BASE_URL',
            'CLIKGATE_LINK_DOMAIN',
            'CLIKGATE_PROGRAM_ID',
          ],
        },
      ],
    ],
  },
  { root, pkg }
);
