/** @type {import('jest').Config} */
module.exports = {
  projects: [
    {
      displayName: 'library',
      preset: '@react-native/jest-preset',
      roots: ['<rootDir>/src'],
      testMatch: ['**/__tests__/**/*.test.ts'],
      modulePathIgnorePatterns: ['<rootDir>/example/node_modules', '<rootDir>/lib'],
    },
    {
      displayName: 'expo-plugin',
      testEnvironment: 'node',
      roots: ['<rootDir>/plugin'],
      testMatch: ['**/__tests__/**/*.test.ts'],
      transform: { '^.+\\.ts$': 'babel-jest' },
      modulePathIgnorePatterns: ['<rootDir>/plugin/build'],
    },
  ],
};
