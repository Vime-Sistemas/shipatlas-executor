import { redis, QUEUE_KEY, RESULTS_KEY } from './redis.js';
import { runDeploy } from './runner.js';
let running = false;
export async function enqueue(payload) {
    const item = { payload, queued_at: new Date().toISOString() };
    await redis.rpush(QUEUE_KEY, JSON.stringify(item));
    // Kick the loop if it's idle
    if (!running)
        processNext();
}
async function processNext() {
    if (running)
        return;
    const raw = await redis.lpop(QUEUE_KEY);
    if (!raw)
        return;
    running = true;
    let item;
    try {
        item = JSON.parse(raw);
    }
    catch {
        console.error('[queue] Failed to parse queued item, discarding');
        running = false;
        processNext();
        return;
    }
    console.log(`[queue] Starting deploy ${item.payload.deploy_id} (runbook: ${item.payload.runbook})`);
    try {
        const result = await runDeploy(item.payload);
        const entry = {
            deploy_id: item.payload.deploy_id,
            result,
            completed_at: new Date().toISOString(),
        };
        await redis.rpush(RESULTS_KEY, JSON.stringify(entry));
        console.log(`[queue] Deploy ${item.payload.deploy_id} finished with status: ${result.status}`);
    }
    catch (err) {
        console.error(`[queue] Unexpected error processing deploy ${item.payload.deploy_id}:`, err);
    }
    finally {
        running = false;
        // Check if there's more work
        processNext();
    }
}
// Resume queue on startup in case the process restarted mid-queue
export async function resumeQueue() {
    const length = await redis.llen(QUEUE_KEY);
    if (length > 0) {
        console.log(`[queue] Resuming — ${length} item(s) pending in queue`);
        processNext();
    }
}
