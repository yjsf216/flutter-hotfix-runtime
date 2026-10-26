const time = value => Number.isFinite(Date.parse(value)) ? Date.parse(value) : 0

// Latest means upload completion, independently for each App/platform/channel. Deleted
// records never displace an available package, and input records stay immutable.
export function baselineRows(records) {
  const ordered = [...records].sort((a, b) => time(b.registeredAt) - time(a.registeredAt)
    || a.baselineId.localeCompare(b.baselineId))
  const seen = new Set()
  return ordered.map(record => {
    const key = JSON.stringify([record.appId, record.platform, record.abi || 'arm64', record.channel || ''])
    const isLatest = !record.deletedAt && time(record.registeredAt) > 0 && !seen.has(key)
    if (isLatest) seen.add(key)
    return { ...record, isLatest }
  })
}

export function formatUploadTime(value) {
  if (!time(value)) return '—'
  return new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).format(new Date(value))
}
