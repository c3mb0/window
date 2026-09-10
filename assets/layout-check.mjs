import { chromium, firefox } from '@playwright/test';
import assert from 'node:assert/strict';

// No capability: this exercises the real fitted terminal without starting a shell.
for (const [name, engine] of Object.entries({ chromium, firefox })) {
  const browser = await engine.launch();
  try {
    const page = await browser.newPage();
    await page.goto(process.env.WINDOW_URL || 'http://127.0.0.1:4050/');
    await page.locator('.xterm-rows > div').first().waitFor();
    for (const [width, height] of [[760,400],[760,500],[1100,699],[1100,700],[1100,721],[1400,900]]) {
      await page.setViewportSize({width,height});
      await page.waitForTimeout(100);
      const boxes = await page.evaluate(() => {
        const rect = selector => {
          const r = document.querySelector(selector).getBoundingClientRect();
          return {top:r.top,bottom:r.bottom,left:r.left,right:r.right};
        };
        return {panel:rect('section'), screen:rect('.xterm-screen'),
          lastRow:rect('.xterm-rows > div:last-child'), viewport:rect('.xterm-viewport'), height:innerHeight};
      });
      for (const key of ['screen','lastRow','viewport']) {
        assert.ok(boxes[key].bottom <= boxes.panel.bottom + .5, `${name} ${width}x${height}: ${key} extends below panel`);
        assert.ok(boxes[key].bottom <= boxes.height - 7.5, `${name}: bottom breathing room lost`);
      }
    }
    console.log(`PASS ${name}: last row, screen and scroll viewport fit at all six sizes`);
  } finally { await browser.close(); }
}
