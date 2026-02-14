# 🌐 Browser Testing Guide

## Overview

Frontend testing is handled via **Playwright MCP** — a Model Context Protocol server that gives AI agents control over a real browser (Chrome/Chromium). Agents can navigate, click, type, take screenshots, and report results.

## Setup

### 1. Install Playwright

```bash
# From the agentic project root
cd /Users/msk/IdeaProjects/agentic
npm init -y
npm install playwright @playwright/test
npx playwright install chromium
```

### 2. Install Playwright MCP Server

```bash
npm install -g @anthropic/mcp-server-playwright
# or use npx
npx @anthropic/mcp-server-playwright
```

### 3. Configure MCP for Claude Code

Create or update `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@anthropic/mcp-server-playwright"],
      "env": {
        "PLAYWRIGHT_HEADLESS": "true"
      }
    }
  }
}
```

### 4. Configure MCP for Gemini CLI

Create or update `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@anthropic/mcp-server-playwright"]
    }
  }
}
```

### 5. Configure MCP for Codex CLI

Create or update `~/.codex/config.toml` or provide via `--mcp-config`:

```toml
[mcp_servers.playwright]
command = "npx"
args = ["@anthropic/mcp-server-playwright"]
```

## Usage

### Via Orchestrator

```bash
./orchestrate.sh \
  --project ~/IdeaProjects/derin-ui-manager \
  --task "Verify login page and dashboard navigation" \
  --browser-test \
  --test-url "http://localhost:4200"
```

### Direct Agent Testing

#### Claude Code (with Chrome integration)

```bash
# Claude Code has a built-in --chrome flag for browser control
claude -p "Navigate to http://localhost:4200, login with admin/admin, \
  go to the Dashboard page, take a screenshot, then go to Settings, \
  take another screenshot. Report any visual issues." \
  --chrome
```

#### Claude Code (with Playwright MCP)

```bash
claude -p "Use the Playwright MCP tools to: \
  1. Open http://localhost:4200 \
  2. Fill in username 'admin' and password 'admin' \
  3. Click the Login button \
  4. Wait for the dashboard to load \
  5. Take a screenshot named 'dashboard.png' \
  6. Click on each sidebar menu item \
  7. Take a screenshot of each page \
  8. Report your findings"
```

#### Gemini CLI (with Playwright MCP)

```bash
gemini -p "Use Playwright to test http://localhost:4200: \
  login with admin/admin, navigate to all main pages, \
  take screenshots, verify no console errors, report issues."
```

## Writing Custom Test Scripts

For repeatable tests, create Playwright test files:

```bash
mkdir -p /Users/msk/IdeaProjects/agentic/tests
```

### Example: Login & Navigate Test

Create `tests/login-navigate.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Login and Navigation', () => {
  test('should login and navigate dashboard', async ({ page }) => {
    // Navigate to login
    await page.goto('http://localhost:4200');
    await page.screenshot({ path: '.agentic/screenshots/01-login-page.png' });

    // Fill credentials
    await page.fill('input[name="username"]', 'admin');
    await page.fill('input[name="password"]', 'admin');
    await page.click('button[type="submit"]');

    // Wait for dashboard
    await page.waitForURL('**/dashboard**');
    await page.screenshot({ path: '.agentic/screenshots/02-dashboard.png' });

    // Navigate sidebar items
    const menuItems = await page.locator('nav a').all();
    for (let i = 0; i < menuItems.length; i++) {
      await menuItems[i].click();
      await page.waitForLoadState('networkidle');
      await page.screenshot({ 
        path: `.agentic/screenshots/03-page-${i}.png` 
      });
    }
  });
});
```

### Running Tests

```bash
npx playwright test tests/login-navigate.spec.ts --reporter=html
```

## Screenshot Reports

Screenshots are saved to `<project>/.agentic/screenshots/`. The orchestrator generates a markdown report referencing these screenshots.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Browser won't launch | Run `npx playwright install chromium` |
| MCP server not found | `npm install -g @anthropic/mcp-server-playwright` |
| Login fails | Check credentials in `config.yaml` |
| Timeout errors | Increase `timeout_ms` in `config.yaml` |
| Port in use | Make sure dev server is running on the expected port |
