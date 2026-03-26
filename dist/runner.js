import { spawn } from 'child_process';
import { existsSync } from 'fs';
import { resolve, join, basename } from 'path';
import { getConfig } from './config.js';
import { startMetrics } from './metrics.js';
const BUILTIN_DIR = resolve(import.meta.dirname, '../../runbooks');
const ZERO_RESOURCES = {
    cpu_peak_percent: 0,
    cpu_avg_percent: 0,
    ram_before_mb: 0,
    ram_peak_mb: 0,
    ram_after_mb: 0,
};
function resolveRunbook(name) {
    const config = getConfig();
    const safe = basename(name);
    if (safe !== name)
        return null;
    if (!config.allowed_runbooks.includes(safe))
        return null;
    const builtinPath = join(BUILTIN_DIR, safe);
    if (existsSync(builtinPath))
        return builtinPath;
    if (config.custom_runbooks_dir) {
        const customPath = join(config.custom_runbooks_dir, safe);
        if (existsSync(customPath))
            return customPath;
    }
    return null;
}
function execScript(scriptPath, env) {
    return new Promise((resolve) => {
        const started_at = new Date();
        const child = spawn('bash', [scriptPath], { env, stdio: 'inherit' });
        // 'spawn' fires synchronously after the process is created — PID is ready
        child.once('spawn', () => {
            const collector = startMetrics(child.pid);
            child.on('close', (code) => {
                const resources = collector.stop();
                resolve({
                    exitCode: code ?? 1,
                    resources,
                    started_at,
                    finished_at: new Date(),
                });
            });
        });
        child.on('error', (err) => {
            resolve({
                exitCode: 1,
                resources: ZERO_RESOURCES,
                started_at,
                finished_at: new Date(),
            });
            // Log but don't crash — caller handles exitCode
            console.error('[runner] Failed to spawn script:', err.message);
        });
    });
}
export async function runDeploy(payload) {
    const scriptPath = resolveRunbook(payload.runbook);
    if (!scriptPath) {
        const now = new Date().toISOString();
        return {
            status: 'failed',
            runbook: payload.runbook,
            service: payload.project_name,
            version: payload.release_version,
            started_at: now,
            finished_at: now,
            duration_ms: { total: 0 },
            resources: ZERO_RESOURCES,
            exit_code: -1,
            error: `Runbook "${payload.runbook}" not found or not allowed`,
        };
    }
    const env = {
        ...process.env,
        DEPLOY_ID: payload.deploy_id,
        BRANCH: payload.branch,
        RELEASE_VERSION: payload.release_version,
        RELEASE_NAME: payload.release_name,
        PROJECT_NAME: payload.project_name,
    };
    const { exitCode, resources, started_at, finished_at } = await execScript(scriptPath, env);
    const total = finished_at.getTime() - started_at.getTime();
    return {
        status: exitCode === 0 ? 'success' : 'failed',
        runbook: payload.runbook,
        service: payload.project_name,
        version: payload.release_version,
        started_at: started_at.toISOString(),
        finished_at: finished_at.toISOString(),
        duration_ms: { total },
        resources,
        exit_code: exitCode,
        error: exitCode !== 0 ? `Script exited with code ${exitCode}` : null,
    };
}
