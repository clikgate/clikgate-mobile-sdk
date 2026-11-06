import { VERSION } from '../version';

const pkg = require('../../package.json');

it('VERSION matches package.json (sent as the wrapper version)', () => {
  expect(VERSION).toBe(pkg.version);
});
