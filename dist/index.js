import 'dotenv/config';
import Fastify from 'fastify';
import { validateAuth } from './auth.js';
import { getConfig } from './config.js';
import { enqueue, resumeQueue } from './queue.js';
import { redis, RESULTS_KEY } from './redis.js';
const app = Fastify({ logger: true });
// Validate config on startup — fail fast if misconfigured
getConfig();
app.get('/health', async () => ({ status: 'ok' }));
// POST /deploy/init — enqueues the deploy, returns 202 immediately
app.post('/deploy/init', async (request, reply) => {
    if (!validateAuth(request, reply))
        return;
    const { deploy_id, branch, release_version, release_name, project_name, runbook } = request.body;
    if (!deploy_id || !branch || !release_version || !release_name || !project_name || !runbook) {
        return reply.status(400).send({ error: 'Missing required fields' });
    }
    await enqueue({ deploy_id, branch, release_version, release_name, project_name, runbook });
    return reply.status(202).send({ queued: true, deploy_id });
});
// GET /deploy/results — returns all completed results and clears them atomically
// Called by the worker every 10 minutes to collect and report to backend
app.get('/deploy/results', async (request, reply) => {
    if (!validateAuth(request, reply))
        return;
    // LMPOP atomically pops all items — fallback to manual drain for older Redis
    const length = await redis.llen(RESULTS_KEY);
    if (length === 0)
        return reply.send([]);
    const pipeline = redis.pipeline();
    for (let i = 0; i < length; i++)
        pipeline.lpop(RESULTS_KEY);
    const responses = await pipeline.exec();
    const results = [];
    for (const [err, raw] of responses ?? []) {
        if (err || !raw)
            continue;
        try {
            results.push(JSON.parse(raw));
        }
        catch {
            // discard malformed entry
        }
    }
    return reply.send(results);
});
const port = Number(process.env.PORT ?? 9000);
const host = process.env.HOST ?? '0.0.0.0';
app.listen({ port, host }, async (err) => {
    if (err) {
        app.log.error(err);
        process.exit(1);
    }
    await resumeQueue();
});
