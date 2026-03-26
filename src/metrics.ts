import { readFileSync, readdirSync } from 'fs'
import { cpus } from 'os'

const POLL_INTERVAL_MS = 500
const CPU_CORES = cpus().length
// Kernel clock ticks per second — standard on Linux
const CLK_TCK = 100

export interface ResourceSnapshot {
  cpu_peak_percent: number
  cpu_avg_percent: number
  ram_before_mb: number
  ram_peak_mb: number
  ram_after_mb: number
}

// Read /proc/<pid>/stat — returns [utime, stime] in clock ticks
function readPidCpuTicks(pid: number): number {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf-8')
    const fields = stat.split(' ')
    const utime = parseInt(fields[13], 10)
    const stime = parseInt(fields[14], 10)
    return utime + stime
  } catch {
    return 0
  }
}

// Read VmRSS from /proc/<pid>/status in kB, returns MB
function readPidRamMb(pid: number): number {
  try {
    const status = readFileSync(`/proc/${pid}/status`, 'utf-8')
    const match = status.match(/VmRSS:\s+(\d+)\s+kB/)
    return match ? Math.round(parseInt(match[1], 10) / 1024) : 0
  } catch {
    return 0
  }
}

// Walk /proc/<pid>/task/<tid>/children recursively to get all descendant PIDs
function collectPidTree(pid: number, visited = new Set<number>()): number[] {
  if (visited.has(pid)) return []
  visited.add(pid)

  const result: number[] = [pid]

  try {
    const tasks = readdirSync(`/proc/${pid}/task`)
    for (const tid of tasks) {
      try {
        const childrenRaw = readFileSync(`/proc/${pid}/task/${tid}/children`, 'utf-8')
        for (const childPid of childrenRaw.trim().split(/\s+/).filter(Boolean)) {
          const child = parseInt(childPid, 10)
          result.push(...collectPidTree(child, visited))
        }
      } catch {
        // task may have exited
      }
    }
  } catch {
    // process may have exited
  }

  return result
}

function totalRamMb(rootPid: number): number {
  const pids = collectPidTree(rootPid)
  return pids.reduce((sum, pid) => sum + readPidRamMb(pid), 0)
}

function totalCpuTicks(rootPid: number): number {
  const pids = collectPidTree(rootPid)
  return pids.reduce((sum, pid) => sum + readPidCpuTicks(pid), 0)
}

export interface MetricsCollector {
  stop: () => ResourceSnapshot
}

export function startMetrics(rootPid: number): MetricsCollector {
  const ramBefore = totalRamMb(rootPid)

  let ramPeak = ramBefore
  let lastTicks = totalCpuTicks(rootPid)
  let lastTime = Date.now()

  const cpuSamples: number[] = []

  const timer = setInterval(() => {
    const nowTicks = totalCpuTicks(rootPid)
    const nowTime = Date.now()

    const deltaTicks = nowTicks - lastTicks
    const deltaTime = (nowTime - lastTime) / 1000  // seconds

    if (deltaTime > 0) {
      // CPU percent across all cores
      const cpuPercent = Math.round((deltaTicks / CLK_TCK / deltaTime / CPU_CORES) * 100)
      cpuSamples.push(Math.min(cpuPercent, 100 * CPU_CORES))
    }

    const ram = totalRamMb(rootPid)
    if (ram > ramPeak) ramPeak = ram

    lastTicks = nowTicks
    lastTime = nowTime
  }, POLL_INTERVAL_MS)

  return {
    stop(): ResourceSnapshot {
      clearInterval(timer)

      const ramAfter = totalRamMb(rootPid)
      const cpuPeak = cpuSamples.length > 0 ? Math.max(...cpuSamples) : 0
      const cpuAvg =
        cpuSamples.length > 0
          ? Math.round(cpuSamples.reduce((a, b) => a + b, 0) / cpuSamples.length)
          : 0

      return {
        cpu_peak_percent: cpuPeak,
        cpu_avg_percent: cpuAvg,
        ram_before_mb: ramBefore,
        ram_peak_mb: ramPeak,
        ram_after_mb: ramAfter,
      }
    },
  }
}
