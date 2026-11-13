const path = require('path');
const { getDefaultConfig } = require('@react-native/metro-config');
const { withMetroConfig } = require('react-native-monorepo-config');

const root = path.resolve(__dirname, '..');

/**
 * Resolves `@clikgate/react-native` (core and its Engage features) to ../src (the package source)
 * and keeps a single copy of react / react-native (the example's).
 *
 * @type {import('metro-config').MetroConfig}
 */
module.exports = withMetroConfig(getDefaultConfig(__dirname), {
  root,
  dirname: __dirname,
  // The package root is not a workspace root (npm, two separate installs).
  workspaces: [],
  conditions: ['clikgate-react-native-source'],
});
