import 'dotenv/config'
import Fastify from 'fastify'
import { validateAuth } from './auth.js'
import { runDeploy } from './runner.js'
import type { DeployPayload } from './runner.js'
import { getConfig } from './config.js'

const app = Fastify({ logger: true })

// Validate config on startup — fail fast if misconfigured
getConfig()

app.get('/health', async () => ({ status: 'ok' }))

app.post<{ Body: Record<string, unknown> }>('/deploy/init', async (request, reply) => {
  if (!validateAuth(request, reply)) return

  const { deploy_id, branch, release_version, release_name, project_name, runbook } =
    request.body as unknown as DeployPayload

  if (!deploy_id || !branch || !release_version || !release_name || !project_name || !runbook) {
    return reply.status(400).send({ error: 'Missing required fields' })
  }

  const result = await runDeploy({ deploy_id, branch, release_version, release_name, project_name, runbook })

  const statusCode = result.status === 'success' ? 200 : 500
  return reply.status(statusCode).send(result)
})

const port = Number(process.env.PORT ?? 9000)
const host = process.env.HOST ?? '0.0.0.0'

app.listen({ port, host }, (err) => {
  if (err) {
    app.log.error(err)
    process.exit(1)
  }
})
