import { parseArgs } from 'node:util';
import { loadConfig } from '../config.js';
import { createPool } from '../infrastructure/db/pool.js';
import { rotateGeneration } from '../infrastructure/db/recovery.js';
import { AuthService } from '../modules/auth/index.js';
import { purgeExpired } from '../modules/maintenance/index.js';

const usage = `Console locale de confiance uniquement :
  npm run admin -- pair --name "iPhone" [--user UUID]
  npm run admin -- devices
  npm run admin -- devices revoke UUID
  npm run admin -- restore-generation [--keep-devices]
  npm run admin -- purge

Le secret d'appairage apparaît une seule fois, expire en 10 minutes et doit être
saisi dans l'iPhone. Ne partagez pas la sortie de cette commande.
restore-generation (après une restauration) : nouvelle génération serveur, et
révocation de tous les appareils sauf --keep-devices. npm run backup -- restore le fait déjà.
purge : purge immédiate de la corbeille expirée (30 jours) ; l'API le fait aussi
une fois par jour. Tombstones et reçus restent conservés jusqu'à la récupération
des anciennes files hors ligne.`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { name: { type: 'string' }, user: { type: 'string' }, 'keep-devices': { type: 'boolean' }, help: { type: 'boolean' } },
  });
  if (values.help || positionals.length === 0) { process.stdout.write(`${usage}\n`); return; }
  const [command, subcommand, deviceId] = positionals;
  const valid = (command === 'pair' && positionals.length === 1 && values.name)
    || (command === 'devices' && positionals.length === 1)
    || (command === 'devices' && subcommand === 'revoke' && positionals.length === 3 && deviceId)
    || (command === 'restore-generation' && positionals.length === 1)
    || (command === 'purge' && positionals.length === 1);
  if (!valid) throw new Error(usage);
  const config = loadConfig();
  if (command === 'restore-generation') {
    if (!config.databaseAdminUrl) throw new Error('DATABASE_ADMIN_URL est requis.');
    const admin = createPool(config.databaseAdminUrl);
    try {
      const result = await rotateGeneration(admin, { revokeDevices: !values['keep-devices'] });
      process.stdout.write(`Nouvelle génération serveur : ${result.generation}
Appareils révoqués : ${result.revokedDevices}
`);
    } finally { await admin.end(); }
    return;
  }
  const pool = createPool(config.databaseUrl);
  if (command === 'purge') {
    try {
      const counts = await purgeExpired(pool, new Date());
      process.stdout.write(`Purge faite : ${counts.tasks} tâche(s), ${counts.projects} liste(s), ${counts.reminders} rappel(s), `
        + `${counts.aiActions} entrée(s) de journal IA, ${counts.tombstones} tombstone(s), ${counts.receipts} reçu(s), `
        + `${counts.transcriptions} transcription(s).\n`);
    } finally { await pool.end(); }
    return;
  }
  try {
    const service = new AuthService(pool, config.auth);
    await service.ready();
    if (command === 'pair') {
      const result = await service.createPairingSecret({ name: values.name!, ...(values.user ? { userId: values.user } : {}) });
      // The only intentional secret output is this trusted interactive console.
      // One link carries the server address and the secret, to paste into the iPhone (a QR comes later).
      const link = `planner://pair?api=${encodeURIComponent(config.publicApiUrl)}&secret=${encodeURIComponent(result.pairingSecret)}`;
      process.stdout.write(`Secret d'appairage : ${result.pairingSecret}\nLien à coller dans l'iPhone : ${link}\nExpire à : ${result.expiresAt}\n`);
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
