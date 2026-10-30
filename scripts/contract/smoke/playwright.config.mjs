// Page smoke test: the real dashboard server on the made-up game folder (start-fixture-server.ps1).
import { defineConfig } from '@playwright/test';

const port = Number(process.env.SMOKE_PORT || 8790);

export default defineConfig({
  testDir: '.',
  testMatch: 'smoke.spec.mjs',
  workers: 1,
  retries: 0,
  timeout: 60000,
  reporter: [['list']],
  outputDir: 'test-results',
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    headless: true,
  },
  webServer: {
    command: `powershell -NoProfile -ExecutionPolicy Bypass -File start-fixture-server.ps1 -Port ${port}`,
    url: `http://127.0.0.1:${port}/api/health`,
    reuseExistingServer: false,
    timeout: 90000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
