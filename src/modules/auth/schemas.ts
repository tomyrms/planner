import { z } from 'zod';

const device = z.strictObject({
  name: z.string().trim().min(1).max(100),
  platform: z.literal('ios'),
  osVersion: z.string().min(1).max(50),
  appVersion: z.string().min(1).max(50),
});

export const authSchemas = {
  pair: z.strictObject({ pairingSecret: z.string().min(1).max(200), device }),
  refresh: z.strictObject({ refreshToken: z.string().min(1).max(200) }),
  tokens: z.strictObject({
    deviceId: z.uuid(),
    accessToken: z.string(),
    accessTokenExpiresAt: z.iso.datetime(),
    refreshToken: z.string(),
    serverGeneration: z.uuid(),
  }),
  sync: z.strictObject({ token: z.string(), expiresAt: z.iso.datetime(), endpoint: z.url().nullable() }),
  logout: z.strictObject({ revoked: z.literal(true) }),
  error: z.strictObject({ error: z.strictObject({ code: z.string(), message: z.string(), requestId: z.string() }) }),
};

export type PairInput = z.infer<typeof authSchemas.pair>;
export type TokenResponse = z.infer<typeof authSchemas.tokens>;

const json = (schema: z.ZodType) => z.toJSONSchema(schema, { target: 'draft-7' });
const errors = { 400: json(authSchemas.error), 401: json(authSchemas.error), 429: json(authSchemas.error) };
export const authRouteSchemas = {
  pair: { body: json(authSchemas.pair), response: { 201: json(authSchemas.tokens), ...errors } },
  refresh: { body: json(authSchemas.refresh), response: { 200: json(authSchemas.tokens), ...errors } },
  sync: { response: { 200: json(authSchemas.sync), ...errors } },
  logout: { response: { 200: json(authSchemas.logout), ...errors } },
};
