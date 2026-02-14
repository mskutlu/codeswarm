#!/usr/bin/env bash
#
# setup.sh — Install dependencies for the Agentic Orchestration Framework
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}🤖 Agentic Setup${NC}"
echo ""

# ─── Check Prerequisites ────────────────────────────────
check_cmd() {
  if command -v "$1" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $1 found: $(command -v "$1")"
    return 0
  else
    echo -e "  ${RED}✗${NC} $1 not found"
    return 1
  fi
}

echo -e "${BOLD}Checking prerequisites...${NC}"
MISSING=0
check_cmd "claude"  || MISSING=1
check_cmd "gemini"  || MISSING=1
check_cmd "codex"   || MISSING=1
check_cmd "node"    || MISSING=1
check_cmd "npm"     || MISSING=1
check_cmd "git"     || MISSING=1

if [[ $MISSING -eq 1 ]]; then
  echo ""
  echo -e "${YELLOW}⚠ Some tools are missing. Install them before running the orchestrator.${NC}"
  echo ""
  echo "  Install CLI agents:"
  echo "    Claude Code: npm install -g @anthropic/claude-code"
  echo "    Gemini CLI:  npm install -g @anthropic/gemini-cli (or via Google's installer)"
  echo "    Codex CLI:   npm install -g @openai/codex"
  echo ""
fi

# ─── Install Node Dependencies ──────────────────────────
echo ""
echo -e "${BOLD}Installing Node dependencies...${NC}"
cd "$SCRIPT_DIR"

if [[ ! -f package.json ]]; then
  npm init -y --silent
fi

npm install --save-dev playwright @playwright/test 2>/dev/null || true

echo ""
echo -e "${BOLD}Installing Playwright browsers...${NC}"
npx playwright install chromium 2>/dev/null || true

# ─── Make scripts executable ─────────────────────────────
chmod +x "$SCRIPT_DIR/orchestrate.sh"
chmod +x "$SCRIPT_DIR/setup.sh"

# ─── MCP Configuration ──────────────────────────────────
echo ""
echo -e "${BOLD}MCP Configuration${NC}"
echo ""
echo "  To enable Playwright MCP for each agent, add the following:"
echo ""
echo -e "  ${YELLOW}Claude Code${NC} (~/.claude/mcp.json):"
echo '    { "mcpServers": { "playwright": { "command": "npx", "args": ["@anthropic/mcp-server-playwright"] } } }'
echo ""
echo -e "  ${YELLOW}Gemini CLI${NC} (~/.gemini/settings.json):"
echo '    { "mcpServers": { "playwright": { "command": "npx", "args": ["@anthropic/mcp-server-playwright"] } } }'
echo ""
echo -e "  ${YELLOW}Codex CLI${NC} (~/.codex/config.toml):"
echo '    [mcp_servers.playwright]'
echo '    command = "npx"'
echo '    args = ["@anthropic/mcp-server-playwright"]'
echo ""

# ─── Create Example Test ─────────────────────────────────
mkdir -p "$SCRIPT_DIR/tests"
if [[ ! -f "$SCRIPT_DIR/tests/example.spec.ts" ]]; then
  cat > "$SCRIPT_DIR/tests/example.spec.ts" << 'EOTEST'
import { test, expect } from '@playwright/test';

test.describe('Smoke Test', () => {
  test('should load login page', async ({ page }) => {
    await page.goto(process.env.TEST_URL || 'http://localhost:4200');
    await page.screenshot({ path: '.codeswarm/screenshots/login-page.png' });
    // Verify the page loads without errors
    const title = await page.title();
    expect(title).toBeTruthy();
  });

  test('should login and navigate', async ({ page }) => {
    const baseUrl = process.env.TEST_URL || 'http://localhost:4200';
    await page.goto(baseUrl);

    // Attempt login (adjust selectors to your app)
    const usernameInput = page.locator('input[type="text"], input[name="username"], #username');
    const passwordInput = page.locator('input[type="password"], input[name="password"], #password');
    const loginButton = page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Giriş")');

    if (await usernameInput.isVisible()) {
      await usernameInput.fill(process.env.TEST_USER || 'admin');
      await passwordInput.fill(process.env.TEST_PASS || 'admin');
      await loginButton.click();
      await page.waitForTimeout(3000);
      await page.screenshot({ path: '.codeswarm/screenshots/after-login.png' });
    }
  });
});
EOTEST
  echo -e "  ${GREEN}✓${NC} Created example test: tests/example.spec.ts"
fi

# ─── Create .gitignore ───────────────────────────────────
if [[ ! -f "$SCRIPT_DIR/.gitignore" ]]; then
  cat > "$SCRIPT_DIR/.gitignore" << 'EOIGNORE'
node_modules/
.codeswarm/
*.log
test-results/
playwright-report/
EOIGNORE
  echo -e "  ${GREEN}✓${NC} Created .gitignore"
fi

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  Next steps:"
echo "    1. Review config.yaml and adjust defaults"
echo "    2. Run: ./orchestrate.sh --project <path> --task \"your task\""
echo ""
