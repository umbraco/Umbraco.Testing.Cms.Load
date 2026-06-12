// Mirror our config onto the env var names @umbraco-cms/acceptance-test-helpers
// reads (URL / UMBRACO_USER_LOGIN / UMBRACO_USER_PASSWORD). The package freezes
// baseUrl at import time, so this must run BEFORE it is required — hence it is
// imported first in playwright.config.ts (in the main process, before workers
// inherit the env). `??=` so an explicitly-set package var always wins.
import { env } from './env';

process.env.URL ??= env.baseUrl;
process.env.UMBRACO_USER_LOGIN ??= env.user;
process.env.UMBRACO_USER_PASSWORD ??= env.password;
