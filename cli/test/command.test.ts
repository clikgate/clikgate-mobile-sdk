import { afterEach, describe, expect, it, vi } from 'vitest';
import { helpText } from '../src/args';
import { DEFAULT_SETUP_COMMAND, setupCommand, setupSubcommand } from '../src/command';
import type { DoctorReport } from '../src/doctor';
import { main } from '../src/index';
import { ScriptedUI, copyFixture } from './helpers';

// CLIKGATE_SETUP_COMMAND: `dart run clikgate_flutter` runs this program as a binary and sets it, so every
// command the tool prints is one the person can run.
describe('the command it prints', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('defaults to npx @clikgate/setup', () => {
    expect(setupCommand({})).toBe(DEFAULT_SETUP_COMMAND);
    expect(setupSubcommand('doctor', {})).toBe('npx @clikgate/setup doctor');
    expect(setupSubcommand('website', {})).toBe('npx @clikgate/setup website');
    expect(helpText({})).toContain('\n  npx @clikgate/setup [options]          interactive setup\n  npx @clikgate/setup doctor [options]   checks only');
  });

  it('dart run clikgate_flutter: doctor is its own executable', () => {
    const env = { CLIKGATE_SETUP_COMMAND: 'dart run clikgate_flutter' };
    expect(setupCommand(env)).toBe('dart run clikgate_flutter');
    expect(setupSubcommand('doctor', env)).toBe('dart run clikgate_flutter:doctor');
    expect(setupSubcommand('website', env)).toBe('dart run clikgate_flutter website');
    expect(setupSubcommand('doctor', { CLIKGATE_SETUP_COMMAND: 'fvm dart run clikgate_flutter' })).toBe('fvm dart run clikgate_flutter:doctor');
    const help = helpText(env);
    expect(help).toContain('\n  dart run clikgate_flutter [options]          interactive setup\n  dart run clikgate_flutter:doctor [options]   checks only');
    expect(help).not.toContain('npx');
  });

  it('ignores an empty or unusual value', () => {
    expect(setupCommand({ CLIKGATE_SETUP_COMMAND: '  ' })).toBe(DEFAULT_SETUP_COMMAND);
    expect(setupCommand({ CLIKGATE_SETUP_COMMAND: 'x; rm -rf ~' })).toBe(DEFAULT_SETUP_COMMAND);
    expect(setupCommand({ CLIKGATE_SETUP_COMMAND: 'a\nb' })).toBe(DEFAULT_SETUP_COMMAND);
  });

  it('doctor --json fixes name the same command (no npx) when started by dart run', async () => {
    vi.stubEnv('CLIKGATE_SETUP_COMMAND', 'dart run clikgate_flutter');
    const dir = copyFixture('flutter');
    let out = '';
    const spy = vi.spyOn(process.stdout, 'write').mockImplementation((chunk: string | Uint8Array) => {
      out += chunk.toString();
      return true;
    });
    try {
      await main(['doctor', '--json', '--cwd', dir], { ui: new ScriptedUI([], false) });
    } finally {
      spy.mockRestore();
    }
    const report = JSON.parse(out) as DoctorReport;
    const texts = report.checks.flatMap((c) => [c.fix ?? '', c.detail ?? '']);
    expect(texts.some((t) => t.includes('`dart run clikgate_flutter`'))).toBe(true);
    expect(texts.some((t) => t.includes('`dart run clikgate_flutter:doctor`'))).toBe(true);
    expect(texts.filter((t) => t.includes('npx'))).toEqual([]);
  });

  it('usage errors name the website command the same way', async () => {
    vi.stubEnv('CLIKGATE_SETUP_COMMAND', 'dart run clikgate_flutter');
    let err = '';
    const spy = vi.spyOn(process.stderr, 'write').mockImplementation((chunk: string | Uint8Array) => {
      err += chunk.toString();
      return true;
    });
    try {
      expect(await main(['--web-key', 'cgw_test_a'])).toBe(1);
    } finally {
      spy.mockRestore();
    }
    expect(err).toContain('(dart run clikgate_flutter website)');
  });
});
