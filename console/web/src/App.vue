<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'

const menus = ['基础版本', '补丁构建', '发布管理', '运行结果']
const tab = ref('基础版本')
const token = ref('') // Deliberately never stored in browser storage or URL.
const loggedIn = ref(false)
const state = ref({ tasks: [], baselines: [], patches: [], commits: [], prerequisites: {} })
const error = ref('')
const notice = ref('')
const busy = ref(false)
const commit = ref('')
const baseline = ref('')
const selectedTask = ref('')
const log = ref('')
const counts = ref(null)
const pending = ref(null)
const confirmation = ref(null)
let timer
const tasks = computed(() => [...state.value.tasks].reverse())
const bases = computed(() => [...state.value.baselines].reverse())
const patches = computed(() => [...state.value.patches].reverse())
const statusLabels = { queued: '等待中', running: '执行中', succeeded: '成功', failed: '失败', interrupted: '已中断', ready: '待验收', published: '已发布', withdrawn: '已撤回', 'publication-unknown': '发布结果待确认' }
const actionLabels = { build: '构建基线', patch: '生成补丁', publish: '发布补丁', withdraw: '撤回补丁', refresh: '同步提交' }
const short = (value) => value?.slice(0, 12) || '—'
const date = (value) => value ? new Date(value).toLocaleString() : '—'

async function api(path, body) {
  const response = await fetch(path, { headers: { Authorization: `Bearer ${token.value}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, method: body ? 'POST' : 'GET', ...(body ? { body: JSON.stringify(body) } : {}) })
  if (!response.ok) {
    if (response.status === 401) loggedIn.value = false
    const result = await response.json()
    throw new Error(result.error || '请求失败')
  }
  return response.json()
}
async function refresh() {
  state.value = await api('/api/state')
  if (!baseline.value && state.value.baselines.length) baseline.value = state.value.baselines.at(-1).id
  if (selectedTask.value) log.value = (await api(`/api/log/${selectedTask.value}`)).text
}
async function login() {
  error.value = ''
  try { await refresh(); loggedIn.value = true } catch (e) { error.value = e.message }
}
function logout() { loggedIn.value = false; token.value = ''; log.value = ''; counts.value = null; state.value = { tasks: [], baselines: [], patches: [], commits: [], prerequisites: {} } }
function dismissConfirmation() { confirmation.value.close(); pending.value = null }
async function confirmTask() {
  const choice = pending.value
  dismissConfirmation()
  if (choice) await submit(choice.action, choice.patch, true)
}
async function submit(action, patch, confirmed = false) {
  if (!confirmed && ['build', 'publish', 'withdraw'].includes(action)) {
    const base = patch ? state.value.baselines.find(b => b.id === patch.baselineRef) : null
    pending.value = { action, patch, base }
    await nextTick()
    confirmation.value.showModal()
    return
  }
  error.value = ''; notice.value = ''; busy.value = true
  try {
    let body = { action, commit: commit.value, baseline: baseline.value }
    if (patch) {
      body = { action, patch: patch.id, confirmed: true }
    }
    const task = await api('/api/tasks', body)
    selectedTask.value = task.id
    notice.value = '任务已提交。生成成功不代表已发布；发布成功也不代表用户已生效。'
    await refresh()
  } catch (e) { error.value = e.message } finally { busy.value = false }
}
async function showLog(task) {
  selectedTask.value = task.id
  try { log.value = (await api(`/api/log/${task.id}`)).text } catch (e) { error.value = e.message }
}
async function stats() {
  error.value = ''; counts.value = null
  try { counts.value = (await api(`/api/stats/${baseline.value}`)).eventCounts } catch (e) { error.value = e.message }
}
async function download(base) {
  error.value = ''
  try {
    const response = await fetch(`/api/package/${base.id}`, { headers: { Authorization: `Bearer ${token.value}` } })
    if (!response.ok) throw new Error((await response.json()).error)
    const url = URL.createObjectURL(await response.blob())
    const a = document.createElement('a'); a.href = url; a.download = `${base.release}.${base.platform === 'ios' ? 'ipa' : 'apk'}`; a.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  } catch (e) { error.value = e.message }
}
onMounted(() => { timer = setInterval(async () => { if (loggedIn.value && !busy.value) { try { await refresh() } catch (e) { error.value = e.message } } }, 2500) })
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <main v-if="!loggedIn" class="login">
    <form class="login-card" @submit.prevent="login">
      <div class="brand-mark">F</div><h1>Flutter Hotfix</h1><p class="muted">独立热更新控制台 · 无 Jenkins 依赖</p>
      <label for="token">本机管理令牌</label><input id="token" v-model="token" type="password" autocomplete="off" required placeholder="从启动提示的 access-token 文件获取">
      <p class="hint">令牌仅保留在本页内存中。此后台仅用于本机可信项目。</p>
      <p v-if="error" role="alert" class="error">{{ error }}</p><button class="primary">进入控制台</button>
    </form>
  </main>
  <div v-else class="layout">
    <dialog ref="confirmation" @cancel.prevent="dismissConfirmation" aria-labelledby="confirmation-title">
      <template v-if="pending"><h2 id="confirmation-title">确认{{ actionLabels[pending.action] }}</h2>
        <p v-if="pending.action === 'build'">在专用构建副本中构建基线安装包，不会安装设备或自动分发。iOS IPA 需要有效签名和设备授权，不能像 APK 一样直接网页安装。</p>
        <p v-else-if="pending.action === 'withdraw'">签名并发布撤回指令。客户端下次检查后按回退策略处理，不会即时改变运行中的应用；撤回不能取消。</p>
        <p v-else>将此补丁发布给对应基线的用户。请确认已在测试环境完成业务验收。</p>
        <dl v-if="pending.patch"><dt>App</dt><dd>{{ pending.base?.appId }}</dd><dt>基础版本</dt><dd>{{ pending.base?.release }}</dd><dt>补丁</dt><dd>{{ pending.patch.patchId }}</dd><dt>发布目标</dt><dd>{{ pending.base?.origin }}</dd></dl>
        <p v-else><code>{{ commit }}</code></p><div class="actions"><button autofocus @click="dismissConfirmation">取消</button><button class="primary" @click="confirmTask">确认{{ actionLabels[pending.action] }}</button></div>
      </template>
    </dialog>
    <aside><div class="brand"><span class="brand-mark">F</span> Flutter Hotfix</div><nav aria-label="主导航"><button v-for="menu in menus" :key="menu" :class="{ active: tab === menu }" @click="tab = menu">{{ menu }}</button></nav><div class="sidebar-footer">Android / iOS · 本机单人版<br>编译 / 签名 / 分发</div></aside>
    <div class="main"><header><span>热更新管理 / {{ tab }}</span><div><span class="project">{{ state.project }} · {{ state.platform === 'ios' ? 'iOS' : 'Android' }}</span><button @click="logout">退出</button></div></header>
      <section class="content"><div class="page-heading"><div><h1>{{ tab }}</h1><p class="muted">选择明确的版本和提交，让每次修复都有据可查。</p></div><span class="badge" :class="state.active ? 'running' : 'succeeded'">{{ state.active ? '任务执行中' : '执行器空闲' }}</span></div>
        <div v-if="error" role="alert" class="message error">{{ error }}</div><div v-if="notice" role="status" class="message success">{{ notice }}</div>
        <div v-if="Object.values(state.prerequisites).some(v => !v)" class="message error">工具链路径有缺失，请按首次接入文档补齐后再构建。</div>
        <div v-if="tab === '基础版本'" class="card"><h2>构建并归档新版本</h2><p class="hint">基线是完整发行归档，不是任意 Git 节点。必须安装这里生成的 APK / IPA，才能使用对应补丁。iOS 开发包仅供签名授权的设备测试。</p><div class="controls"><label>发行提交<select v-model="commit"><option value="">选择 Git 提交</option><option v-for="c in state.commits" :key="c.sha" :value="c.sha">{{ short(c.sha) }} · {{ c.subject }}</option></select></label><button :disabled="busy || state.active" @click="submit('refresh')">同步提交</button><button class="primary" :disabled="!commit || busy || state.active" @click="submit('build')">构建基础版本</button></div>
          <div class="table-wrap"><table><thead><tr><th>基础版本</th><th>App / 平台</th><th>提交</th><th>基线 ID</th><th>操作</th></tr></thead><tbody><tr v-for="b in bases" :key="b.id"><td>{{ b.release }}</td><td>{{ b.appId }} / {{ b.platform || 'android' }}</td><td><code>{{ short(b.commit) }}</code></td><td :title="b.baselineId"><code>{{ short(b.baselineId) }}</code></td><td><button @click="download(b)">下载 {{ b.platform === 'ios' ? 'IPA' : 'APK' }}</button></td></tr><tr v-if="!bases.length"><td colspan="5" class="empty">还没有基线，请先构建一个基础版本。</td></tr></tbody></table></div>
        </div>
        <div v-if="tab === '补丁构建'" class="card"><h2>生成修复补丁</h2><p class="hint">版本号必须与基线一致。原生、依赖、结构或其他不兼容修改会被拒绝，不会绕过检查。</p><div class="controls"><label>基础版本<select v-model="baseline"><option value="">选择基线</option><option v-for="b in bases" :key="b.id" :value="b.id">{{ b.release }} · {{ short(b.commit) }} · {{ short(b.baselineId) }}</option></select></label><label>修复提交<select v-model="commit"><option value="">选择 Git 提交</option><option v-for="c in state.commits" :key="c.sha" :value="c.sha">{{ short(c.sha) }} · {{ c.subject }}</option></select></label><button class="primary" :disabled="!baseline || !commit || busy || state.active" @click="submit('patch')">生成补丁</button></div><p class="hint">构建副本：{{ state.workspace }}。不会切换你的原工程分支，不会自动发布。</p></div>
        <div v-if="tab === '发布管理'" class="card"><h2>补丁列表</h2><p class="hint">发布前自行完成测试。目标地址来自冻结基线，无法通过页面临时替换。撤回无法撤销，修复后需生成新补丁。</p><div class="table-wrap"><table><thead><tr><th>补丁</th><th>基础版本</th><th>修复提交</th><th>状态</th><th>操作</th></tr></thead><tbody><tr v-for="p in patches" :key="p.id"><td>{{ p.patchId }}</td><td>{{ state.baselines.find(b => b.id === p.baselineRef)?.release }}</td><td><code>{{ short(p.commit) }}</code></td><td><span class="badge" :class="p.status">{{ statusLabels[p.status] }}</span></td><td class="actions"><button :disabled="busy || state.active || p.status === 'withdrawn' || p.withdrawalStarted" @click="submit('publish', p)">{{ p.status === 'publication-unknown' ? '重试原包发布' : '发布' }}</button><button class="danger" :disabled="busy || state.active || !['published', 'publication-unknown'].includes(p.status)" @click="submit('withdraw', p)">撤回</button></td></tr><tr v-if="!patches.length"><td colspan="5" class="empty">还没有补丁，请先生成。</td></tr></tbody></table></div></div>
        <div v-if="tab === '运行结果'" class="card"><h2>客户端结果事件</h2><div class="controls"><label>基础版本<select v-model="baseline"><option value="">选择基线</option><option v-for="b in bases" :key="b.id" :value="b.id">{{ b.release }} · {{ short(b.baselineId) }}</option></select></label><button :disabled="!baseline" @click="stats">查询结果</button></div><p class="hint">这里是服务端去重后的事件数，不是独立用户数，也不能直接计算用户成功率。</p><div v-if="counts" class="table-wrap"><table><thead><tr><th>补丁</th><th>结果</th><th>事件数</th></tr></thead><tbody><tr v-for="(value, key) in counts" :key="key"><td>{{ key.split('/')[1] }}</td><td>{{ key.split('/')[2] }}</td><td>{{ value }}</td></tr><tr v-if="!Object.keys(counts).length"><td colspan="3" class="empty">暂未收到事件。</td></tr></tbody></table></div></div>
        <div class="card"><h2>任务记录</h2><div class="table-wrap"><table><thead><tr><th>操作</th><th>状态</th><th>开始时间</th><th>说明</th><th>日志</th></tr></thead><tbody><tr v-for="t in tasks" :key="t.id"><td>{{ actionLabels[t.action] }}</td><td><span class="badge" :class="t.status">{{ statusLabels[t.status] }}</span></td><td>{{ date(t.startedAt || t.createdAt) }}</td><td>{{ t.error || short(t.commit) }}</td><td><button @click="showLog(t)">查看日志</button></td></tr><tr v-if="!tasks.length"><td colspan="5" class="empty">提交任务后在这里查看进度。</td></tr></tbody></table></div><template v-if="selectedTask"><h3>任务日志 · {{ short(selectedTask) }}</h3><pre aria-live="polite">{{ log || '等待日志输出…' }}</pre><p class="hint">刷新不会取消任务；日志显示最近 256 KiB，完整日志位于本机管理目录。</p></template></div>
      </section>
    </div>
  </div>
</template>
