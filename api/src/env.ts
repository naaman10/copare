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
    const errors = parsed.error.flatten().fieldErrors;
    console.error('Invalid environment:', errors);
    if (errors.DATABASE_URL) {
      console.error('Set DATABASE_URL in the Render Dashboard (Environment tab).');
    }
    process.exit(1);
  }
  return parsed.data;
}

export function loadEnv(): Env {
  const parsed = apiEnvSchema.safeParse(process.env);
  if (!parsed.success) {
    const errors = parsed.error.flatten().fieldErrors;
    console.error('Invalid environment:', errors);
    if (errors.NEON_AUTH_BASE_URL) {
      console.error('Set NEON_AUTH_BASE_URL in the Render Dashboard (Environment tab).');
    }
    if (errors.DATABASE_URL) {
      console.error('Set DATABASE_URL in the Render Dashboard (Environment tab).');
    }
    process.exit(1);
  }
  return parsed.data;
}
