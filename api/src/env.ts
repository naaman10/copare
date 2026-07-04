import { config } from 'dotenv';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

// Load api/.env in local dev; production env vars come from the host (e.g. Render).
config({ path: resolve(dirname(fileURLToPath(import.meta.url)), '../.env') });

const databaseEnvSchema = z.object({
  DATABASE_URL: z.string().url(),
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
});

const apiEnvSchema = databaseEnvSchema.extend({
  NEON_AUTH_BASE_URL: z.string().url(),
  PORT: z.coerce.number().default(3000),
});

export type DatabaseEnv = z.infer<typeof databaseEnvSchema>;
export type Env = z.infer<typeof apiEnvSchema>;

export function loadDatabaseEnv(): DatabaseEnv {
  const parsed = databaseEnvSchema.safeParse(process.env);
  if (!parsed.success) {
    console.error('Invalid environment:', parsed.error.flatten().fieldErrors);
    process.exit(1);
  }
  return parsed.data;
}

export function loadEnv(): Env {
  const parsed = apiEnvSchema.safeParse(process.env);
  if (!parsed.success) {
    console.error('Invalid environment:', parsed.error.flatten().fieldErrors);
    process.exit(1);
  }
  return parsed.data;
}
