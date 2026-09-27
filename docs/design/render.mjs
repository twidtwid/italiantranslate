// Renders docs/design/card.html into the images in docs/images.
// Usage: node docs/design/render.mjs   (Playwright + Chromium: npm i -D playwright && npx playwright install chromium)
// Offline: FONTS_DIR=/path/with/woff2-and-local.css serves the Google Fonts from disk instead.
import { chromium } from "playwright";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "images");
const page = pathToFileURL(join(here, "card.html")).href;

const renders = [
  { file: "banner.png", query: "layout=wide&rounded", width: 1280, height: 640, scale: 2, transparent: true },
  { file: "social-preview.png", query: "layout=wide", width: 1280, height: 640, scale: 1 },
  { file: "social-square.png", query: "layout=square", width: 1080, height: 1080, scale: 1 },
];

const browser = await chromium.launch();
for (const r of renders) {
  const context = await browser.newContext({ viewport: { width: r.width, height: r.height }, deviceScaleFactor: r.scale });
  const tab = await context.newPage();
  const fonts = process.env.FONTS_DIR;
  if (fonts) {
    await tab.route(/fonts\.(googleapis|gstatic)\.com/, (route) => {
      const url = new URL(route.request().url());
      if (url.hostname === "fonts.googleapis.com" && url.pathname.startsWith("/css")) {
        return route.fulfill({ contentType: "text/css", body: readFileSync(join(fonts, "local.css"), "utf8") });
      }
      const file = join(fonts, basename(url.pathname));
      return existsSync(file) ? route.fulfill({ contentType: "font/woff2", body: readFileSync(file) }) : route.abort();
    });
  }
  await tab.goto(`${page}?${r.query}`);
  await tab.evaluate(() => document.fonts.ready);
  await tab.locator(".card").screenshot({ path: join(out, r.file), omitBackground: !!r.transparent });
  console.log(`wrote docs/images/${r.file}`);
  await context.close();
}
await browser.close();
