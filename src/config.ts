import { existsSync, readFileSync } from 'node:fs';
import { loadEnvFile } from 'node:process';
import { z } from 'zod';
import type { AuthConfig } from './modules/auth/index.js';

const environmentSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HOST: z.string().default('127.0.0.1'),
  PORT: z.coerce.number().int().min(1).max(65535).default(4317),
  DATABASE_URL: z.url(),
  DATABASE_ADMIN_URL: z.url().optional(),
  AUTH_ISSUER: z.url(),
  AUTH_API_AUDIENCE: z.string().min(1).default('planner-api'),
  AUTH_SYNC_AUDIENCE: z.string().min(1).default('planner-sync'),
  AUTH_KEY_ID: z.string().min(1),
  AUTH_PRIVATE_KEY_PATH: z.string().min(1),
  AUTH_PUBLIC_KEY_PATH: z.string().min(1),
  AUTH_REFRESH_DERIVATION_KEY: z.string().regex(/^[a-fA-F0-9]{64}$/),
  MIN_CLIENT_VERSION: z.string().regex(/^\d{1,6}\.\d{1,6}\.\d{1,6}$/).default('0.1.0'),
});

export interface AppConfig {
  environment: 'development' | 'test' | 'production';
  host: string;
  port: number;
  databaseUrl: string;
  databaseAdminUrl?: string;
  auth: AuthConfig;
  minimumClientVersion: string;
}

export function loadConfig(): AppConfig {
  if (existsSync('.env')) loadEnvFile('.env');
  const parsed = environmentSchema.safeParse(process.env);
  // Never include a rejected value (e.g. a database URL) in the diagnostic.
  if (!parsed.success) {
    throw new Error(`Invalid configuration fields: ${parsed.error.issues.map(issue => issue.path.join('.')).join(', ')}`);
  }
  const env = parsed.data;
  if (env.NODE_ENV === 'production' && new URL(env.AUTH_ISSUER).protocol !== 'https:') {
    throw new Error('Production AUTH_ISSUER requires HTTPS.');
  }
  return {
    environment: env.NODE_ENV,
    host: env.HOST,
    port: env.PORT,
    databaseUrl: env.DATABASE_URL,
    ...(env.DATABASE_ADMIN_URL ? { databaseAdminUrl: env.DATABASE_ADMIN_URL } : {}),
    minimumClientVersion: env.MIN_CLIENT_VERSION,
    auth: {
      issuer: env.AUTH_ISSUER,
      apiAudience: env.AUTH_API_AUDIENCE,
      syncAudience: env.AUTH_SYNC_AUDIENCE,
      keyId: env.AUTH_KEY_ID,
      privateKeyPem: readFileSync(env.AUTH_PRIVATE_KEY_PATH, 'utf8'),
      publicKeyPem: readFileSync(env.AUTH_PUBLIC_KEY_PATH, 'utf8'),
      refreshDerivationKey: env.AUTH_REFRESH_DERIVATION_KEY,
    },
  };
}
