import { readFileSync } from 'fs'
import { resolve } from 'path'

export interface ExecutorConfig {
  allowed_runbooks: string[]
  custom_runbooks_dir?: string  // absolute path to custom runbooks directory
}

let _config: ExecutorConfig | null = null

export function getConfig(): ExecutorConfig {
  if (_config) return _config

  const configPath = process.env.EXECUTOR_CONFIG ?? resolve(process.cwd(), 'config.json')

  try {
    const raw = readFileSync(configPath, 'utf-8')
    _config = JSON.parse(raw) as ExecutorConfig
  } catch {
    throw new Error(`Failed to load executor config from ${configPath}`)
  }

  if (!Array.isArray(_config.allowed_runbooks) || _config.allowed_runbooks.length === 0) {
    throw new Error('config.json must define at least one allowed_runbook')
  }

  return _config
}
