import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';

// Local development only. Never overwrite an existing database password or signing key.
if (existsSync('.env')) {
  console.log('Configuration .env déjà présente, conservée.');
  process.exit(0);
}
mkdirSync('.local', { recursive: true });
if (existsSync('.local/auth-private.pem') || existsSync('.local/auth-public.pem')) {
  throw new Error('Clés existantes sans .env : restaurer la configuration avant de continuer.');
}
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 3072,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
const adminPassword = randomBytes(32).toString('hex');
const apiPassword = randomBytes(32).toString('hex');
writeFileSync('.local/auth-private.pem', privateKey, { flag: 'wx', mode: 0o600 });
writeFileSync('.local/auth-public.pem', publicKey, { flag: 'wx', mode: 0o644 });
writeFileSync('.env', [
  'NODE_ENV=development',
  'HOST=127.0.0.1',
  'PORT=4317',
  `POSTGRES_PASSWORD=${adminPassword}`,
  `PLANNER_API_PASSWORD=${apiPassword}`,
  `DATABASE_URL=postgresql://planner_api:${apiPassword}@127.0.0.1:55437/planner`,
  `DATABASE_ADMIN_URL=postgresql://planner_owner:${adminPassword}@127.0.0.1:55437/planner`,
  'AUTH_ISSUER=http://localhost:4317',
  'AUTH_API_AUDIENCE=planner-api',
  'AUTH_SYNC_AUDIENCE=planner-sync',
  'AUTH_KEY_ID=planner-local-1',
  'AUTH_PRIVATE_KEY_PATH=.local/auth-private.pem',
  'AUTH_PUBLIC_KEY_PATH=.local/auth-public.pem',
  `AUTH_REFRESH_DERIVATION_KEY=${randomBytes(32).toString('hex')}`,
  '',
].join('\n'), { flag: 'wx', mode: 0o600 });
console.log('Configuration locale créée ; secrets conservés uniquement dans .env et .local/.');
