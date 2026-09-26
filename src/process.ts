import { execFile } from 'node:child_process';

export interface CommandResult {
  stdout: string;
  stderr: string;
}

export function runCommand(command: string, args: string[]): Promise<CommandResult> {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      {
        maxBuffer: 64 * 1024 * 1024,
        windowsHide: true
      },
      (error, stdout, stderr) => {
        const output = {
          stdout: String(stdout ?? ''),
          stderr: String(stderr ?? '')
        };

        if (error) {
          const message = output.stderr.trim() || error.message;
          const wrapped = new Error(`${command} failed: ${message}`);
          wrapped.cause = error;
          reject(wrapped);
          return;
        }

        resolve(output);
      }
    );
  });
}

export async function commandVersion(command: string, args: string[]): Promise<string> {
  const result = await runCommand(command, args);
  const firstLine = result.stdout.trim().split(/\r?\n/, 1)[0];
  return firstLine || result.stderr.trim().split(/\r?\n/, 1)[0] || 'unknown';
}
