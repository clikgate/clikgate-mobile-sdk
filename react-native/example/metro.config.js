const path = require('path');
const { getDefaultConfig } = require('@react-native/metro-config');
const { withMetroConfig } = require('react-native-monorepo-config');

const root = path.resolve(__dirname, '..');
/** The Engage add-on package (pure TypeScript), a sibling of the core package in this repo. */
const engageRoot = path.resolve(__dirname, '..', '..', 'react-native-engage');

/**
 * Resolves `@clikgate/react-native` to ../src (the package source) and keeps a single copy
 * of react / react-native (the example's).
 *
 * @type {import('metro-config').MetroConfig}
 */
const config = withMetroConfig(getDefaultConfig(__dirname), {
  root,
  dirname: __dirname,
  // The package root is not a workspace root (npm, two separate installs).
  workspaces: [],
  conditions: ['clikgate-react-native-source'],
});

/**
 * `@clikgate/react-native-engage` resolves to ../../react-native-engage/src. Bare imports made
 * from the Engage sources (`react-native`, `@clikgate/react-native`) are resolved as if made from
 * the example, so there is one copy of each (its own node_modules, if any, is ignored).
 */
const upstream = config.resolver.resolveRequest;
const escape = (p) => p.replace(/[/\\^$*+?.()|[\]{}-]/g, '\\$&');
module.exports = {
  ...config,
  watchFolders: [...(config.watchFolders ?? []), engageRoot],
  resolver: {
    ...config.resolver,
    blockList: [
      ...[].concat(config.resolver.blockList ?? []),
      new RegExp(`^${escape(path.join(engageRoot, 'node_modules'))}[/\\\\]`),
    ],
    resolveRequest(context, moduleName, platform) {
      if (moduleName === '@clikgate/react-native-engage') {
        return {
          type: 'sourceFile',
          filePath: path.join(engageRoot, 'src', 'index.ts'),
        };
      }
      const bare = !moduleName.startsWith('.') && !path.isAbsolute(moduleName);
      const ctx =
        bare && context.originModulePath.startsWith(engageRoot + path.sep)
          ? { ...context, originModulePath: path.join(__dirname, 'index.js') }
          : context;
      return (upstream ?? ctx.resolveRequest)(ctx, moduleName, platform);
    },
  },
};
