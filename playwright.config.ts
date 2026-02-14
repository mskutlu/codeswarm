import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: './tests',
    timeout: 30000,
    retries: 1,
    use: {
        baseURL: process.env.TEST_URL || 'http://localhost:4200',
        headless: true,
        screenshot: 'on',
        video: 'retain-on-failure',
        trace: 'on-first-retry',
    },
    reporter: [
        ['html', { outputFolder: 'playwright-report' }],
        ['json', { outputFile: '.agentic/test-results.json' }],
    ],
    outputDir: '.agentic/screenshots',
});
