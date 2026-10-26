<script setup>
import { computed, ref } from 'vue'
import { baselineRows, formatUploadTime } from './baseline_list.js'

const token = ref('')
const loggedIn = ref(false)
const records = ref([])
const events = ref({})
const busy = ref(false)
const error = ref('')
const notice = ref('')
const tab = ref('基础版本')
const labels = { uploaded: '待发布', published: '已发布', withdrawn: '已撤回' }
const baselines = ref([])
const retention = ref(null)
const includeDeleted = ref(false)
const includeDeletedPatches = ref(false)
const orderedBaselines = computed(() => baselineRows(baselines.value.map(record => ({ ...record,
  channel: retention.value?.records.find(item => item.baselineId === record.baselineId)?.channel || '',
}))))
const short = value => value?.slice(0, 12) || '—'

async function api(path, body, allowMissing = false) {
  const response = await fetch(new URL(path, document.baseURI), {
    method: body ? 'POST' : 'GET', redirect: 'error',
    headers: { Authorization: `Bearer ${token.value}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  if (allowMissing && response.status === 404) return null
  if (!response.ok) {
    if (response.status === 401) logout()
    throw new Error(`请求失败（HTTP ${response.status}），请检查权限、签名有效期及服务状态。`)
  }
  return response.json()
}
async function refresh() {
  busy.value = true; error.value = ''
  try {
    records.value = await api(`v1/uploads${includeDeletedPatches.value ? '?includeDeleted=1' : ''}`)
    baselines.value = await api(`v1/baselines${includeDeleted.value ? '?includeDeleted=1' : ''}`)
    retention.value = await api('v1/retention', undefined, true)
    loggedIn.value = true
    events.value = (await api('v1/stats')).eventCounts
  } catch (e) { error.value = e.message } finally { busy.value = false }
}
function logout() {
  token.value = ''; loggedIn.value = false; records.value = []; baselines.value = []; events.value = {}; notice.value = ''
  includeDeleted.value = false
  includeDeletedPatches.value = false
  retention.value = null
}
async function manageBaseline(record, action) {
  const removing = action === 'delete'
  const title = `${record.appId} / ${record.platform} / ${record.release}\n基线：${record.baselineId}`
  if (!window.confirm(`${removing ? '删除这条基础版本记录？' : '恢复这条基础版本记录？'}\n${title}\n${removing ? '仅从默认列表移除，可在“显示已删除”中恢复。不会删除 CDN 安装包、本地归档或停止已有补丁分发。' : '恢复后重新出现在基础版本列表中。'}`)) return
  busy.value = true; error.value = ''; notice.value = ''
  try {
    await api(`v1/baselines/${record.baselineId}/${action}`, {})
    notice.value = removing ? '记录已删除，可勾选“显示已删除”后恢复；安装包文件仍保留。' : '基础版本记录已恢复。'
    await refresh()
  } catch (e) { error.value = e.message } finally { busy.value = false }
}
async function managePatch(record, action) {
  const m = record.manifest
  const removing = action === 'delete'
  if (!window.confirm(`${removing ? '删除这条补丁记录？' : '恢复这条补丁记录？'}\n${m.identity.appId} / ${m.identity.platform} / ${m.identity.release}\n补丁：${m.patchId}\n${removing ? '仅从默认列表移除，可在“显示已删除”中恢复。不会删除 CDN 文件或回收补丁编号，也不替代撤回。' : '只恢复列表记录，不会自动发布；已撤回补丁仍不可重新发布。'}`)) return
  busy.value = true; error.value = ''; notice.value = ''
  try {
    await api(`v1/uploads/${m.baselineId}/${m.patchId}/${action}`, {})
    notice.value = removing ? '补丁记录已删除，可勾选“显示已删除”后恢复；文件和编号仍保留。' : '补丁记录已恢复，发布状态未改变。'
    await refresh()
  } catch (e) { error.value = e.message } finally { busy.value = false }
}
async function activate(record, kind) {
  const m = record.manifest
  if (!window.confirm(`确认${kind === 'withdrawal' ? '撤回' : '发布'} ${m.patchId}？\n${m.identity.appId} / ${m.identity.platform} / ${m.identity.release}\n客户端需检查更新并冷启动后生效。`)) return
  busy.value = true; error.value = ''; notice.value = ''
  try {
    await api('v1/activate', { baselineId: m.baselineId, patchId: m.patchId, kind })
    notice.value = '操作已完成，客户端结果请查看运行结果。'
    await refresh()
  } catch (e) { error.value = e.message } finally { busy.value = false }
}
</script>

<template>
  <main v-if="!loggedIn" class="login"><form class="login-card" @submit.prevent="refresh">
    <div class="brand-mark">F</div><h1>热更新发布管理</h1>
    <p class="muted">本机制作补丁，服务端管理发布</p>
    <label for="access">管理凭据</label><input id="access" v-model="token" type="password" autocomplete="off" required>
    <p class="hint">凭据只保存在当前页面内存中。</p>
    <p v-if="error" role="alert" class="error">{{ error }}</p><button class="primary" :disabled="busy">登录</button>
  </form></main>
  <div v-else class="layout">
    <aside><div class="brand">Flutter Hotfix</div><nav aria-label="主导航"><button v-for="name in ['基础版本', '补丁发布', '运行结果']" :key="name" :class="{active: tab === name}" @click="tab = name">{{ name }}</button></nav></aside>
    <div class="main"><header><span>热更新管理 / {{ tab }}</span><button :disabled="busy" @click="logout">退出</button></header>
      <section class="content"><div class="page-heading"><h1>{{ tab }}</h1><button :disabled="busy" @click="refresh">刷新</button></div>
        <p v-if="error" class="message error" role="alert">{{ error }}</p><p v-if="notice" class="message success" role="status">{{ notice }}</p>
        <div v-if="tab === '基础版本'" class="card">
          <p v-if="retention" class="hint">维护策略：同一 App / 平台 / 渠道保留最近两个成功基线。
            <strong>{{ retention.enabled ? '自动淘汰已启用' : '自动淘汰未启用，仅预览，不删除现有版本' }}</strong>。
            预计淘汰 {{ retention.plannedRetirements.length }} 个；仅管理新流程显式登记的基线，历史记录不自动纳入。
            <span v-if="retention.records.some(item => item.retiredAt && item.cleanupStatus !== 'complete')">有退役版本尚未完成存储/CDN 清理，不能视为旧下载地址已失效。</span>
          </p>
          <div class="baseline-tools"><p class="hint">按上传完成时间倒序，同一 App / 平台标记“最新上传”，不代表已发布或最高版本。时间按浏览器本地时区显示。</p><label class="deleted-toggle"><input v-model="includeDeleted" type="checkbox" :disabled="busy" @change="refresh">显示已删除</label></div>
          <p class="hint">删除仅移除管理记录，可恢复；不会删除 CDN 文件、本地归档或停止补丁分发。iOS 安装仍受签名与设备授权限制。</p>
          <div class="table-wrap"><table><thead><tr><th>App</th><th>平台</th><th>版本 / 状态</th><th>上传完成时间</th><th>来源分支 / 提交</th><th>基线 / 构建提交</th><th>安装包</th><th>操作</th></tr></thead><tbody>
            <tr v-for="m in orderedBaselines" :key="m.baselineId" :class="{'latest-baseline': m.isLatest, 'deleted-baseline': m.deletedAt}">
              <td>{{ m.appId }}</td><td>{{ m.platform }}<br><small>{{ m.channel || '未纳入保留策略' }}</small></td>
              <td>{{ m.release }}<br><span v-if="m.isLatest" class="latest-badge">最新上传</span><span v-else-if="m.deletedAt" class="deleted-badge">已删除</span></td>
              <td class="upload-time" :title="m.registeredAt">{{ formatUploadTime(m.registeredAt) }}<small v-if="m.deletedAt">删除于 {{ formatUploadTime(m.deletedAt) }}</small></td>
              <td>{{ m.sourceBranch }}<br>{{ short(m.sourceCommit) }}</td><td :title="m.baselineId">{{ short(m.baselineId) }}<br>{{ short(m.gitCommit) }}</td>
              <td><a v-if="m.packageUrl.startsWith('https://')" :href="m.packageUrl" target="_blank" rel="noopener noreferrer">下载 {{ m.platform === 'ios' ? 'IPA' : 'APK' }}</a><br>{{ (m.packageSize / 1048576).toFixed(1) }} MiB</td>
              <td><button v-if="m.deletedAt" :disabled="busy" @click="manageBaseline(m, 'restore')">恢复</button><button v-else class="danger" :disabled="busy" @click="manageBaseline(m, 'delete')">删除</button></td>
            </tr>
            <tr v-if="!orderedBaselines.length"><td colspan="8" class="empty">暂无基础包，请上传基础包或勾选“显示已删除”查看已移除记录。</td></tr>
          </tbody></table></div>
        </div>
        <div v-if="tab === '补丁发布'" class="card">
          <div class="baseline-tools"><p class="hint">按上传完成时间倒序，最新在前。时间按浏览器本地时区显示；历史记录使用服务端文件时间。</p><label class="deleted-toggle"><input v-model="includeDeletedPatches" type="checkbox" :disabled="busy" @change="refresh">显示已删除</label></div>
          <p class="hint">上传后需确认发布。已发布补丁须先撤回再删除；撤回需先上传本机签名的撤回清单。删除可恢复，不删除文件或回收编号；已撤回补丁不能重新发布。</p>
          <div class="table-wrap"><table><thead><tr><th>补丁</th><th>App / 平台 / 版本</th><th>基线</th><th>上传完成时间</th><th>状态</th><th>操作</th></tr></thead><tbody>
            <tr v-for="r in records" :key="r.manifest.baselineId + r.manifest.patchId" :class="{'deleted-baseline': r.deletedAt}">
              <td>{{ r.manifest.patchNumber ? `p${r.manifest.patchNumber}` : '旧版（无编号）' }}<br><small>{{ r.manifest.patchId }}</small></td><td>{{ r.manifest.identity.appId }} / {{ r.manifest.identity.platform }} / {{ r.manifest.identity.release }}</td>
              <td :title="r.manifest.baselineId">{{ short(r.manifest.baselineId) }}</td>
              <td class="upload-time" :title="r.uploadedAt">{{ formatUploadTime(r.uploadedAt) }}<small v-if="r.deletedAt">删除于 {{ formatUploadTime(r.deletedAt) }}</small></td>
              <td>{{ labels[r.status] }}<br><span v-if="r.deletedAt" class="deleted-badge">已删除</span></td>
              <td class="actions"><template v-if="!r.deletedAt"><button :disabled="busy || r.status !== 'uploaded'" @click="activate(r, 'candidate')">发布</button><button class="danger" :disabled="busy || r.status !== 'published' || !r.withdrawalUploaded" @click="activate(r, 'withdrawal')">撤回</button><button class="danger" :disabled="busy || r.status === 'published'" :title="r.status === 'published' ? '请先撤回已发布补丁' : '可恢复地删除列表记录'" @click="managePatch(r, 'delete')">删除</button></template><button v-else :disabled="busy" @click="managePatch(r, 'restore')">恢复</button></td>
            </tr><tr v-if="!records.length"><td colspan="6" class="empty">暂无补丁，请先上传或勾选“显示已删除”查看已移除记录。</td></tr>
          </tbody></table></div>
        </div>
        <div v-if="tab === '运行结果'" class="card"><p class="hint">服务端去重事件数，不代表独立用户数或成功率。</p><div class="table-wrap"><table><thead><tr><th>基线 / 补丁 / 事件</th><th>数量</th></tr></thead><tbody><tr v-for="(count, key) in events" :key="key"><td>{{ key }}</td><td>{{ count }}</td></tr></tbody></table></div></div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.baseline-tools { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
.baseline-tools .hint { flex: 1; margin: 0; min-width: 240px; }
.deleted-toggle { display: inline-flex; align-items: center; gap: 8px; white-space: nowrap; font-size: 13px; }
.deleted-toggle input { width: auto; margin: 0; }
.latest-baseline { background: #f0f8ff; }
.latest-badge, .deleted-badge { display: inline-block; padding: 3px 7px; margin-top: 6px; border-radius: 4px; font-size: 12px; }
.latest-badge { background: #dceeff; color: #155ca4; font-weight: 600; }
.deleted-badge { background: #eee; color: #555; }
.deleted-baseline { color: #687383; background: #fafafa; }
.upload-time { white-space: nowrap; font-variant-numeric: tabular-nums; }
.upload-time small { display: block; margin-top: 5px; }
</style>
