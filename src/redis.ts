import { Redis } from 'ioredis'

const REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6379'

export const redis = new Redis(REDIS_URL, {
  maxRetriesPerRequest: 3,
  lazyConnect: true,
})

redis.on('error', (err: Error) => {
  console.error('[redis] Connection error:', err.message)
})

export const QUEUE_KEY = 'deploy:queue'
export const RESULTS_KEY = 'deploy:results'
