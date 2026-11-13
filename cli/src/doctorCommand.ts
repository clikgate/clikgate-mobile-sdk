import type { Options } from './args';
import { setupCommand, setupSubcommand } from './command';
import { EXIT } from './constants';
import { runLocalChecks, serverChecks, summarise, waitForFirstEvent, type Check, type DoctorReport } from './doctor';
import { loadProject, needsPlatforms } from './project/load';
import { chooseProject, connect, printChecks, type Deps, PLATFORM_LABEL } from './setup';
import { paint } from './ui';
import type { App } from './api/clikgate';

/** `npx @clikgate/setup doctor` (S.5). Changes nothing. Exit 1 when any check fails. */
export async function runDoctor(opts: Options, deps: Deps): Promise<{ code: number; report: DoctorReport }> {
  const { ui } = deps;
  const candidate = await chooseProject(opts, ui);
  const project = await loadProject(ui, candidate);
  const checks: Check[] = runLocalChecks({
    root: project.root,
    platform: candidate.platform,
    android: project.android,
    ios: project.ios,
    expectedLiveDomains: opts.domains,
    appConfig: candidate.appConfig,
  });
  const next: { message: string; doc_url: string | null }[] = [];

  // Clikgate's side needs sign-in: only in a terminal, and only when the person agrees.
  const canSignIn = ui.interactive && !opts.json && !opts.sdkKey;
  if (canSignIn && (await ui.confirm("Sign in to Clikgate to also check your app's links on Clikgate's side?", true))) {
    const { clikgate } = await connect(opts, deps, project);
    const all = await clikgate.listApps();
    const apps: { id: string; platform: 'android' | 'ios' }[] = [];
    for (const platform of needsPlatforms(project)) {
      const id = platform === 'android' ? project.androidAppId : project.iosBundleId;
      const app: App | undefined = opts.app
        ? all.find((a) => a.id === opts.app && a.platform === platform)
        : all.find((a) => a.platform === platform && (platform === 'android' ? a.package_name : a.bundle_id)?.toLowerCase() === id?.toLowerCase());
      if (!app) {
        checks.push({ id: `clikgate.${platform}.app`, group: 'clikgate', status: 'fail', title: `No Clikgate ${platform === 'ios' ? 'iOS' : 'Android'} app uses ${id ?? 'this project'}`, fix: 'Run `' + setupCommand() + '` to create or pick it.' });
        continue;
      }
      apps.push({ id: app.id, platform });
      const r = serverChecks({ id: app.id, platform }, await clikgate.setupCheck(app.id));
      checks.push(...r.checks);
      next.push(...r.next);
    }
    if (opts.wait && apps.length) {
      ui.out('Waiting for the first event from your app… (up to 5 minutes, press Enter to skip)');
      const ac = new AbortController();
      const live = await waitForFirstEvent(clikgate, apps, deps.liveWaitMs ?? 5 * 60_000, { sleep: deps.sleep, now: deps.now, skip: ui.waitForEnter(ac.signal) });
      ac.abort();
      checks.push(live);
    }
  } else {
    checks.push({
      id: 'clikgate.signed_in',
      group: 'clikgate',
      status: 'skip',
      title: 'Clikgate checks skipped (not signed in)',
      detail: 'run `' + setupSubcommand('doctor') + '` in a terminal and sign in to check app-links files and events',
    });
  }

  const report = summarise(project.root, candidate.platform, checks, next);
  if (opts.json) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } else {
    ui.out(`Clikgate doctor: ${PLATFORM_LABEL[candidate.platform]} project`);
    printChecks(ui, checks);
    for (const n of next) ui.out(`  • ${n.message}${n.doc_url ? ` (${n.doc_url})` : ''}`);
    ui.out('');
    const s = report.summary;
    ui.out(
      report.ok
        ? paint(ui, 'green', `No problems found (${s.passed} passed, ${s.warnings} warning${s.warnings === 1 ? '' : 's'}).`)
        : paint(ui, 'red', `${s.failed} problem${s.failed === 1 ? '' : 's'} found (${s.passed} passed, ${s.warnings} warning${s.warnings === 1 ? '' : 's'}).`)
    );
  }
  return { code: report.ok ? EXIT.OK : EXIT.PROBLEMS, report };
}
