// Renders single frames to PNG for review. Usage: node frame.js outdir t1 t2 ...
const puppeteer = require('puppeteer-core'), path = require('path');
(async () => {
  const dir = process.argv[2], ts = process.argv.slice(3).map(Number);
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 } });
  const page = await browser.newPage(); page.on('pageerror', e => console.error('page error:', e.message));
  await page.goto('file://' + path.resolve(__dirname, 'launch.html')); await page.evaluate(() => window.ready);
  console.log(await page.evaluate(() => JSON.stringify({ lastClean: Math.max(...CR.list.map(c => c.ce)), lastSpawn: Math.max(...CR.list.map(c => c.spawn)), sumGB: CR.list.reduce((a, c) => a + c.gb, 0) })));
  for (const t of ts) { await page.evaluate(t => window.render(t), t); await (await page.$('#c')).screenshot({ path: `${dir}/f_${String(t).replace('.', '_')}.png` }); }
  await browser.close();
})();
