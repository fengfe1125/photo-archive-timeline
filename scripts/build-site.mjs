import { readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import { build } from 'esbuild';

let url = process.env.SUPABASE_URL;
let key = process.env.SUPABASE_PUBLISHABLE_KEY;
if (!url || !key) {
  const config = await readFile('ios/Local.xcconfig', 'utf8').catch(() => '');
  url ??= config.match(/^SUPABASE_URL\s*=\s*(.+)$/m)?.[1].trim().replace('https:/$()/', 'https://');
  key ??= config.match(/^SUPABASE_PUBLISHABLE_KEY\s*=\s*(.+)$/m)?.[1].trim();
}
if (!url?.startsWith('https://') || !key?.startsWith('sb_publishable_')) {
  throw new Error('设置线上 SUPABASE_URL 和 SUPABASE_PUBLISHABLE_KEY 后再构建网页');
}
await mkdir('site', { recursive: true });
await cp('public/index.html', 'site/index.html');
await cp('public/styles.css', 'site/styles.css');
await build({
  entryPoints: ['web/app.js'], outfile: 'site/app.js', bundle: true, format: 'esm', minify: true,
  define: { __SUPABASE_URL__: JSON.stringify(url), __SUPABASE_KEY__: JSON.stringify(key) }
});
console.log('site/ 已构建（仅含公开 Supabase 配置）');
