import { createRemoteJWKSet } from 'jose';
import { loadEnv } from '../env.js';

const env = loadEnv();

/** Neon Auth JWKS lives under `{NEON_AUTH_BASE_URL}/.well-known/jwks.json`. */
export function neonAuthJwksUrl(authBaseUrl: string): URL {
  const base = authBaseUrl.endsWith('/') ? authBaseUrl : `${authBaseUrl}/`;
  return new URL('.well-known/jwks.json', base);
}

export const neonAuthIssuer = new URL(env.NEON_AUTH_BASE_URL).origin;
export const neonAuthJWKS = createRemoteJWKSet(neonAuthJwksUrl(env.NEON_AUTH_BASE_URL));
