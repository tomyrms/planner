import { parseArgs } from 'node:util';
import { loadConfig } from '../config.js';
import { createPool } from '../infrastructure/db/pool.js';
import { AuthService } from '../modules/auth/index.js';

const usage = `Console locale de confiance uniquement :
  npm run admin -- pair --name "iPhone" [--user UUID]
  npm run admin -- devices
  npm run admin -- devices revoke UUID

Le secret d'appairage apparaît une seule fois, expire en 10 minutes et doit être
saisi dans l'iPhone. Ne partagez pas la sortie de cette commande.`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { name: { type: 'string' }, user: { type: 'string' }, help: { type: 'boolean' } },
  });
  if (values.help || positionals.length === 0) { process.stdout.write(`${usage}\n`); return; }
  const [command, subcommand, deviceId] = positionals;
  const valid = (command === 'pair' && positionals.length === 1 && values.name)
    || (command === 'devices' && positionals.length === 1)
    || (command === 'devices' && subcommand === 'revoke' && positionals.length === 3 && deviceId);
  if (!valid) throw new Error(usage);
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  try {
    const service = new AuthService(pool, config.auth);
    await service.ready();
    if (command === 'pair') {
      const result = await service.createPairingSecret({ name: values.name!, ...(values.user ? { userId: values.user } : {}) });
      // The only intentional secret output is this trusted interactive console.
      process.stdout.write(`Secret d'appairage : ${result.pairingSecret}\nExpire à : ${result.expiresAt}\n`);
    } else if (subcommand === 'revoke') {
      if (!(await service.revokeDevice(deviceId!))) throw new Error('Appareil inconnu.');
      process.stdout.write('Appareil révoqué. API : immédiat ; sync : au plus 15 minutes.\n');
    } else {
      const devices = await service.listDevices();
      process.stdout.write(`${JSON.stringify(devices, null, 2)}\n`);
    }
  } finally { await pool.end(); }
}

main().catch((error: unknown) => {
  // Avoid dumping database/key configuration or a driver stack to the console.
  process.stderr.write(error instanceof Error && !(error as { code?: string }).code
    ? `${error.message}\n` : 'Commande impossible. Vérifiez la configuration et les migrations locales.\n');
  process.exitCode = 1;
});
