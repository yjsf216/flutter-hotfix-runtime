import test from 'node:test'
import assert from 'node:assert/strict'
import { baselineRows, formatUploadTime } from './baseline_list.js'

test('32-bit and 64-bit packages have independent latest markers', () => {
  const row = { appId: 'one', platform: 'android', channel: 'main', registeredAt: '2026-10-19T10:00:00Z' }
  const result = baselineRows([{ ...row, baselineId: 'a', abi: 'arm' },
    { ...row, baselineId: 'b', abi: 'arm64' }, { ...row, baselineId: 'c' }])
  assert.equal(result.filter(r => r.isLatest).length, 2)
})

test('channels have independent latest baselines', () => {
  const row = { appId: 'one', platform: 'android', registeredAt: '2026-10-19T10:00:00Z' }
  const result = baselineRows([{ ...row, baselineId: 'a', channel: 'main' },
    { ...row, baselineId: 'b', channel: 'beta' }])
  assert.equal(result.filter(r => r.isLatest).length, 2)
})

test('upload time, not version/Git/list order, selects latest independently per app/platform', () => {
  const old = { appId: 'one', platform: 'android', baselineId: 'old', release: '9.0.0+9', registeredAt: '2026-10-19T10:00:00Z' }
  const recent = { ...old, baselineId: 'recent', release: '1.0.0+1', registeredAt: '2026-10-20T10:00:00Z' }
  const ios = { ...old, baselineId: 'ios', platform: 'ios' }
  const otherApp = { ...old, baselineId: 'other', appId: 'two' }
  const input = [old, ios, recent, otherApp]
  const result = baselineRows(input)
  assert.equal(result[0].baselineId, 'recent')
  assert.deepEqual(result.filter(r => r.isLatest).map(r => r.baselineId).sort(), ['ios', 'other', 'recent'])
  assert.equal(input[0], old)
  assert.equal(old.isLatest, undefined)
})

test('deletion, restoration, equal timestamps and missing dates have deterministic latest labels', () => {
  const base = { appId: 'one', platform: 'android', baselineId: 'a', registeredAt: '2026-10-19T10:00:00Z' }
  const newer = { ...base, baselineId: 'b', registeredAt: '2026-10-20T10:00:00Z', deletedAt: '2026-10-21T10:00:00Z' }
  assert.equal(baselineRows([newer, base]).find(r => r.isLatest).baselineId, 'a')
  assert.equal(baselineRows([{ ...newer, deletedAt: undefined }, base]).find(r => r.isLatest).baselineId, 'b')
  assert.equal(baselineRows([base, { ...base, baselineId: 'c' }]).filter(r => r.isLatest).length, 1)
  assert.equal(baselineRows([{ ...base, registeredAt: 'invalid' }])[0].isLatest, false)
  assert.equal(formatUploadTime('invalid'), '—')
  assert.notEqual(formatUploadTime(base.registeredAt), '—')
})
