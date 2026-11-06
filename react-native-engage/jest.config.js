const path = require('path');

/**
 * Tests run against the core package's source (`../react-native/src`) so `ClikgateError` and the
 * `ClikgateRequestContext` type are the real ones. `npm run devlink` (no install) or
 * `npm install` provides node_modules; see README "Development".
 * @type {import('jest').Config}
 */
module.exports = {
  displayName: 'engage',
  preset: '@react-native/jest-preset',
  roots: ['<rootDir>/src'],
  testMatch: ['**/__tests__/**/*.test.ts'],
  modulePathIgnorePatterns: ['<rootDir>/lib'],
  moduleNameMapper: {
    '^@clikgate/react-native$': path.join(__dirname, '..', 'react-native', 'src', 'index.ts'),
  },
};
