// Renders the 16:9 banner to a PNG. Usage: node banner.js out.png
const puppeteer = require('puppeteer-core'), path = require('path');
(async () => {
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 } });
  const page = await browser.newPage(); page.on('pageerror', e => console.error('page error:', e.message));
  await page.goto('file://' + path.resolve(__dirname, 'launch.html')); await page.evaluate(() => window.ready);
  await page.evaluate(() => window.renderBanner());
  await (await page.$('#c')).screenshot({ path: process.argv[2] || 'banner.png' });
  await browser.close(); console.log('wrote', process.argv[2] || 'banner.png');
})();
