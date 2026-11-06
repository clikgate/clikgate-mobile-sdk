const path = require('path');
const pkg = require('../package.json');
const engage = require('../../react-native-engage/package.json');

// Links the package from the parent directory (the monorepo checkout) instead of
// node_modules, so native changes in ../android and ../ios are picked up directly.
module.exports = {
  project: {
    ios: {
      automaticPodsInstallation: false,
    },
  },
  dependencies: {
    [pkg.name]: {
      root: path.join(__dirname, '..'),
      platforms: {
        // Codegen needs both platforms listed explicitly for a library linked by path.
        ios: {},
        android: {},
      },
    },
    // The Engage add-on's share bridge (share.link), linked from ../../react-native-engage.
    [engage.name]: {
      root: path.join(__dirname, '..', '..', 'react-native-engage'),
      platforms: {
        ios: {},
        android: {},
      },
    },
  },
};
