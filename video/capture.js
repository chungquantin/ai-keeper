// Renders video/launch.html frame by frame in Chrome and pipes the frames to ffmpeg. Usage: node capture.js out.mp4 [fps] [seconds]
const puppeteer = require('puppeteer-core'), { spawn } = require('child_process'), path = require('path');
(async () => {
  const out = process.argv[2] || 'out.mp4', fps = +process.argv[3] || 30, secs = +process.argv[4] || 30, audio = process.env.AUDIO;
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', args: ['--force-color-profile=srgb', '--hide-scrollbars'], defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 } });
  const page = await browser.newPage();
  page.on('pageerror', e => console.error('page error:', e.message));
  await page.goto('file://' + path.resolve(__dirname, 'launch.html'));
  await page.evaluate(() => window.ready);
  const args = ['-y', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-'];
  if (audio) args.push('-i', audio);
  args.push('-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', String(fps));
  if (audio) args.push('-c:a', 'aac', '-b:a', '192k', '-shortest');
  args.push('-movflags', '+faststart', out);
  const ff = spawn('ffmpeg', args, { stdio: ['pipe', 'inherit', 'inherit'] });
  const n = Math.round(fps * secs), canvas = await page.$('#c');
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.render(t), i / fps);
    const buf = await canvas.screenshot({ type: 'png' });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 60 === 0) process.stderr.write(`frame ${i}/${n}\n`);
  }
  ff.stdin.end(); await new Promise(r => ff.on('close', r)); await browser.close(); console.log('wrote', out);
})();
