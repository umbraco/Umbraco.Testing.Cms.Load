// Side-effect module: mirror our config onto the environment variable names that
// @umbraco-cms/acceptance-test-helpers reads at IMPORT time (URL /
// UMBRACO_USER_LOGIN / UMBRACO_USER_PASSWORD). Setting these inside makeApi() is
// too late — the package freezes baseUrl when it is first required. This module
// is imported FIRST in playwright.config.ts, so it runs in the main process
// before any worker spawns (workers inherit the env) and before global-setup
// requires the package. `??=` so an explicitly-set package var always wins.
import { env } from './env';

process.env.URL ??= env.baseUrl;
process.env.UMBRACO_USER_LOGIN ??= env.user;
process.env.UMBRACO_USER_PASSWORD ??= env.password;
