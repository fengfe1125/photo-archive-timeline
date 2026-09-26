#!/usr/bin/env node

import { access } from 'node:fs/promises';
import { MediaDatabase } from './database.js';
import { DerivativeService } from './derivatives.js';
import { exportArchive, type GpsPrivacy } from './exporter.js';
import { supportedExtensions } from './file-types.js';
import { commandVersion } from './process.js';
import { scanSource } from './scanner.js';

interface ParsedArgs {
  command: string;
  positionals: string[];
  options: Record<string, string | boolean>;
}

function parseArgs(argv: string[]): ParsedArgs {
  const [command = 'help', ...rest] = argv;
  const positionals: string[] = [];
  const options: Record<string, string | boolean> = {};

  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index];
    if (!value.startsWith('--')) {
      positionals.push(value);
      continue;
    }

    const name = value.slice(2);
    const next = rest[index + 1];
    if (next && !next.startsWith('--')) {
      options[name] = next;
      index += 1;
    } else {
      options[name] = true;
    }
  }

  return { command, positionals, options };
}

function optionString(options: ParsedArgs['options'], name: string, fallback: string): string {
  const value = options[name];
  return typeof value === 'string' ? value : fallback;
}

function printHelp(): void {
  console.log(`摄影档案时间线 v0.1\n
用法:
  npm run dev -- check
  npm run dev -- init --db data/media.db
  npm run dev -- scan <目录> --db data/media.db
  npm run dev -- stats --db data/media.db
  npm run dev -- inspect <文件ID或相对路径> --db data/media.db
  npm run dev -- prepare --db data/media.db
  npm run dev -- export --event 1 --gps omit --db data/media.db
  npm run dev -- export --gps city --db data/media.db

选项:
  --db <路径>       SQLite 文件，默认 data/media.db
  --gps <策略>       导出 GPS：omit（默认）、city、precise
  --event <ID>       导出指定事件；不提供则导出整条时间轴
  --out <目录>       导出父目录，默认 data/exports
  --json             以 JSON 输出（目前 scan/stats/inspect 支持）

支持的扩展名:
  ${supportedExtensions().join(', ')}
`);
}

async function runCheck(): Promise<void> {
  const tools = [
    { name: 'exiftool', command: process.env.EXIFTOOL_BIN ?? 'exiftool', args: ['-ver'] },
    { name: 'ffprobe', command: process.env.FFPROBE_BIN ?? 'ffprobe', args: ['-version'] }
  ];
  const result: Record<string, { available: boolean; version?: string; error?: string }> = {};

  for (const tool of tools) {
    try {
      result[tool.name] = {
        available: true,
        version: await commandVersion(tool.command, tool.args)
      };
    } catch (error) {
      result[tool.name] = {
        available: false,
        error: error instanceof Error ? error.message : String(error)
      };
    }
  }

  console.log(JSON.stringify(result, null, 2));
  if (Object.values(result).some((tool) => !tool.available)) process.exitCode = 1;
}

async function main(): Promise<void> {
  const parsed = parseArgs(process.argv.slice(2));
  const dbPath = optionString(parsed.options, 'db', 'data/media.db');
  const asJson = parsed.options.json === true;

  if (parsed.command === 'help' || parsed.command === '--help' || parsed.command === '-h') {
    printHelp();
    return;
  }

  if (parsed.command === 'check') {
    await runCheck();
    return;
  }

  if (parsed.command === 'init') {
    const database = new MediaDatabase(dbPath);
    database.close();
    console.log(`Initialized SQLite database: ${dbPath}`);
    return;
  }

  const database = new MediaDatabase(dbPath);
  try {
    if (parsed.command === 'scan') {
      const sourcePath = parsed.positionals[0];
      if (!sourcePath) throw new Error('scan requires a source directory');
      await access(sourcePath);
      const summary = await scanSource(database, sourcePath, {
        onProgress: asJson ? undefined : (message) => console.error(message)
      });
      console.log(JSON.stringify(summary, null, 2));
      return;
    }

    if (parsed.command === 'stats') {
      console.log(JSON.stringify(database.stats(), null, 2));
      return;
    }

    if (parsed.command === 'prepare') {
      const derivatives = new DerivativeService(database);
      console.log(JSON.stringify(await derivatives.processAll(), null, 2));
      return;
    }

    if (parsed.command === 'export') {
      const eventOption = parsed.options.event;
      const eventId = typeof eventOption === 'string' ? Number(eventOption) : undefined;
      if (eventId !== undefined && (!Number.isInteger(eventId) || eventId < 1)) {
        throw new Error('event must be a positive integer');
      }
      const gpsOption = optionString(parsed.options, 'gps', 'omit');
      if (gpsOption !== 'omit' && gpsOption !== 'city' && gpsOption !== 'precise') {
        throw new Error('gps must be omit, city, or precise');
      }
      const result = await exportArchive(database, new DerivativeService(database), {
        eventId,
        gpsPrivacy: gpsOption as GpsPrivacy,
        outputDir: optionString(parsed.options, 'out', 'data/exports')
      });
      console.log(JSON.stringify(result, null, 2));
      return;
    }

    if (parsed.command === 'inspect') {
      const query = parsed.positionals[0];
      if (!query) throw new Error('inspect requires a file ID or relative path');
      const details = database.findFileDetails(query);
      if (!details) throw new Error(`Media file not found: ${query}`);
      console.log(JSON.stringify(details, null, 2));
      return;
    }

    printHelp();
  } finally {
    database.close();
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
