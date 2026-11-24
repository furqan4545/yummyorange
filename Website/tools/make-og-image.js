// Renders tools/og-card.html to public/assets/og-image.jpg (1200 × 630), the picture shown when the site is shared.
//   NODE_PATH="$(npm root -g)" node tools/make-og-image.js      (needs Playwright: npm i -g playwright)
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(__dirname, 'og-card.html'));
  await page.waitForLoadState('load');
  await page.screenshot({ path: path.join(__dirname, '..', 'public', 'assets', 'og-image.jpg'), type: 'jpeg', quality: 88, clip: { x: 0, y: 0, width: 1200, height: 630 } });
  await browser.close();
})();
