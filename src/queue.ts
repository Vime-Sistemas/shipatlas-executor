import { redis, QUEUE_KEY, RESULTS_KEY } from './redis.js'
import { runDeploy } from './runner.js'
import type { DeployPayload, RunResult } from './runner.js'

export interface QueuedDeploy {
  payload: DeployPayload
  queued_at: string
}

export interface DeployResult {
  deploy_id: string
  result: RunResult
  completed_at: string
}

let running = false

export async function enqueue(payload: DeployPayload): Promise<void> {
  const item: QueuedDeploy = { payload, queued_at: new Date().toISOString() }
  await redis.rpush(QUEUE_KEY, JSON.stringify(item))
  // Kick the loop if it's idle
  if (!running) processNext()
}

async function processNext(): Promise<void> {
  if (running) return

  const raw = await redis.lpop(QUEUE_KEY)
  if (!raw) return

  running = true

  let item: QueuedDeploy
  try {
    item = JSON.parse(raw) as QueuedDeploy
  } catch {
    console.error('[queue] Failed to parse queued item, discarding')
    running = false
    processNext()
    return
  }

  console.log(`[queue] Starting deploy ${item.payload.deploy_id} (runbook: ${item.payload.runbook})`)

  try {
    const result = await runDeploy(item.payload)

    const entry: DeployResult = {
      deploy_id: item.payload.deploy_id,
      result,
      completed_at: new Date().toISOString(),
    }

    await redis.rpush(RESULTS_KEY, JSON.stringify(entry))
    console.log(`[queue] Deploy ${item.payload.deploy_id} finished with status: ${result.status}`)
  } catch (err) {
    console.error(`[queue] Unexpected error processing deploy ${item.payload.deploy_id}:`, err)
  } finally {
    running = false
    // Check if there's more work
    processNext()
  }
}

// Resume queue on startup in case the process restarted mid-queue
export async function resumeQueue(): Promise<void> {
  const length = await redis.llen(QUEUE_KEY)
  if (length > 0) {
    console.log(`[queue] Resuming — ${length} item(s) pending in queue`)
    processNext()
  }
}
