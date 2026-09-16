import { mkdir, writeFile } from 'node:fs/promises';
import { generateKeyPairSync } from 'node:crypto';
import { buildApp } from '../app.js';
import { createPool } from '../infrastructure/db/pool.js';

// Schema generation needs no database connection, real credentials or .env file.
const keys = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
const pool = createPool('postgresql://unused@127.0.0.1:1/unused');
const { app, openApi } = await buildApp({ pool, auth: {
  issuer: 'https://planner.example.invalid', apiAudience: 'planner-api', syncAudience: 'planner-sync',
  privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, keyId: 'schema-only',
  refreshDerivationKey: '0'.repeat(64),
} });
try {
  await mkdir('docs', { recursive: true });
  await writeFile('docs/openapi.json', `${JSON.stringify(openApi, null, 2)}\n`);
  console.log('OpenAPI généré depuis les schémas des routes : docs/openapi.json');
} finally {
  await app.close();
  await pool.end();
}
