import { createHmac, timingSafeEqual } from 'crypto'
import type { FastifyRequest, FastifyReply } from 'fastify'

// Valid window: ±1 slot of 5 minutes (covers clock skew)
const WINDOW_SECONDS = 300
const ALLOWED_SLOTS = 1

function buildExpectedSignature(key: string, slot: number): string {
  return createHmac('sha256', key).update(String(slot)).digest('hex')
}

function currentSlots(): number[] {
  const now = Math.floor(Date.now() / 1000)
  const current = Math.floor(now / WINDOW_SECONDS)
  // Accept current slot and ±1 to tolerate clock skew
  return Array.from({ length: ALLOWED_SLOTS * 2 + 1 }, (_, i) => current - ALLOWED_SLOTS + i)
}

export function validateAuth(request: FastifyRequest, reply: FastifyReply): boolean {
  const sharedSecret = process.env.EXECUTOR_SHARED_SECRET
  const hmacKey = process.env.EXECUTOR_HMAC_KEY

  if (!sharedSecret || !hmacKey) {
    reply.status(500).send({ error: 'Executor auth not configured' })
    return false
  }

  // Layer 1: shared secret
  const incomingSecret = request.headers['x-secret']
  if (typeof incomingSecret !== 'string') {
    reply.status(401).send({ error: 'Missing X-Secret header' })
    return false
  }

  const secretBuf = Buffer.from(sharedSecret)
  const incomingBuf = Buffer.alloc(secretBuf.length)
  incomingBuf.write(incomingSecret)

  if (secretBuf.length !== incomingBuf.length || !timingSafeEqual(secretBuf, incomingBuf)) {
    reply.status(401).send({ error: 'Invalid secret' })
    return false
  }

  // Layer 2: HMAC temporal signature
  const incomingSignature = request.headers['x-signature']
  if (typeof incomingSignature !== 'string') {
    reply.status(401).send({ error: 'Missing X-Signature header' })
    return false
  }

  const validSlots = currentSlots()
  const isValid = validSlots.some((slot) => {
    const expected = buildExpectedSignature(hmacKey, slot)
    const expectedBuf = Buffer.from(expected, 'hex')
    const incomingBuf = Buffer.from(incomingSignature, 'hex')
    if (expectedBuf.length !== incomingBuf.length) return false
    return timingSafeEqual(expectedBuf, incomingBuf)
  })

  if (!isValid) {
    reply.status(401).send({ error: 'Invalid or expired signature' })
    return false
  }

  return true
}
