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
  ASSISTANT_PROVIDER: z.enum(['deepseek', 'rules', 'disabled']).optional(),
  DEEPSEEK_API_KEY: z.string().min(1).optional(),
  DEEPSEEK_MODEL: z.string().min(1).default('deepseek-flash'),
  DEEPSEEK_BASE_URL: z.url().default('https://api.deepseek.com'),
  DEEPSEEK_THINKING: z.enum(['true', 'false']).default('false'),
  ASSISTANT_MONTHLY_TOKEN_BUDGET: z.coerce.number().int().min(0).default(3_000_000),
});

export type AssistantProviderConfig =
  | { kind: 'deepseek'; apiKey: string; model: string; baseUrl: string; thinking: boolean }
  | { kind: 'rules' }
  | { kind: 'disabled' };

export interface AppConfig {
  environment: 'development' | 'test' | 'production';
  host: string;
  port: number;
  databaseUrl: string;
  databaseAdminUrl?: string;
  auth: AuthConfig;
  minimumClientVersion: string;
  assistant: { provider: AssistantProviderConfig; monthlyTokenBudget: number };
}

export function loadConfig(): AppConfig {
  if (existsSync('.env')) loadEnvFile('.env');
  // Compose passes unset optional variables as empty strings: treat them as absent.
  const parsed = environmentSchema.safeParse(Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== '')));
  // Never include a rejected value (e.g. a database URL) in the diagnostic.
  if (!parsed.success) {
    throw new Error(`Invalid configuration fields: ${parsed.error.issues.map(issue => issue.path.join('.')).join(', ')}`);
  }
  const env = parsed.data;
  if (env.NODE_ENV === 'production' && new URL(env.AUTH_ISSUER).protocol !== 'https:') {
    throw new Error('Production AUTH_ISSUER requires HTTPS.');
  }
  // Default: DeepSeek when a key exists; the rule-based stand-in only outside production (ADR-005).
  const providerKind = env.ASSISTANT_PROVIDER ?? (env.DEEPSEEK_API_KEY ? 'deepseek' : env.NODE_ENV === 'production' ? 'disabled' : 'rules');
  if (providerKind === 'deepseek' && !env.DEEPSEEK_API_KEY) throw new Error('ASSISTANT_PROVIDER=deepseek requires DEEPSEEK_API_KEY.');
  if (providerKind === 'rules' && env.NODE_ENV === 'production') throw new Error('The rule-based assistant is not allowed in production.');
  const provider: AssistantProviderConfig = providerKind === 'deepseek'
    ? { kind: 'deepseek', apiKey: env.DEEPSEEK_API_KEY!, model: env.DEEPSEEK_MODEL, baseUrl: env.DEEPSEEK_BASE_URL, thinking: env.DEEPSEEK_THINKING === 'true' }
    : { kind: providerKind };
  return {
    environment: env.NODE_ENV,
    host: env.HOST,
    port: env.PORT,
    databaseUrl: env.DATABASE_URL,
    ...(env.DATABASE_ADMIN_URL ? { databaseAdminUrl: env.DATABASE_ADMIN_URL } : {}),
    minimumClientVersion: env.MIN_CLIENT_VERSION,
    assistant: { provider, monthlyTokenBudget: env.ASSISTANT_MONTHLY_TOKEN_BUDGET },
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
