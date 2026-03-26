import { readFileSync } from 'fs';
import { resolve } from 'path';
let _config = null;
export function getConfig() {
    if (_config)
        return _config;
    const configPath = process.env.EXECUTOR_CONFIG ?? resolve(process.cwd(), 'config.json');
    try {
        const raw = readFileSync(configPath, 'utf-8');
        _config = JSON.parse(raw);
    }
    catch {
        throw new Error(`Failed to load executor config from ${configPath}`);
    }
    if (!Array.isArray(_config.allowed_runbooks) || _config.allowed_runbooks.length === 0) {
        throw new Error('config.json must define at least one allowed_runbook');
    }
    return _config;
}
