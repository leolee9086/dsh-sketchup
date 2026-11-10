// 原生 Client 模块：复用 Plugins 页提供的配置表单和 Host 持久化通道。
window.__ModuleLoader__.load({
  id: '@leolee9086/dsh-sketchup',
  factory: (require) => {
    const React = require('react')
    const { createElement: h, useState, useRef } = React
    const NS = 'sketchup.settings'
    const fields = ['allowPluginWrite', 'allowPluginLoad', 'allowRubyExecute']
    const dictionaries = {
      zh: {
        summary: '管理 SketchUp 插件写入、加载和 Ruby 脚本执行权限。',
        permissions: 'SketchUp 权限',
        allowPluginWrite: '允许写入插件文件',
        allowPluginWriteHint: '允许在 SketchUp 的 Plugins 子目录中写入 Ruby 文件，已有文件会备份。',
        allowPluginLoad: '允许加载插件',
        allowPluginLoadHint: '允许加载或重新加载 Plugins 目录中的 Ruby 插件。',
        allowRubyExecute: '允许执行 Ruby 脚本',
        allowRubyExecuteHint: '允许在明确指定的 SketchUp 实例中执行 Ruby，脚本具有该进程的权限。',
        note: '这三个开关对当前 Host 的所有 SketchUp 连接生效。保存后自动同步，工具调用仍需显式确认。',
        unavailable: '配置尚未就绪。请确认桥接插件已启用，再重新打开此页面。',
        readOnly: '当前连接没有修改配置的权限。',
        save: '保存', saving: '保存中…', saved: '已保存', discard: '放弃修改',
        failed: '保存未被接受，可能是配置已在别处修改。已保留你的选择，请重新打开页面核对后再保存。',
      },
      en: {
        summary: 'Manage SketchUp plugin writing, loading and Ruby execution permissions.',
        permissions: 'SketchUp permissions',
        allowPluginWrite: 'Allow plugin file writes',
        allowPluginWriteHint: 'Write Ruby files under SketchUp’s Plugins directory, backing up existing files.',
        allowPluginLoad: 'Allow plugin loading',
        allowPluginLoadHint: 'Load or reload Ruby plugins from the Plugins directory.',
        allowRubyExecute: 'Allow Ruby execution',
        allowRubyExecuteHint: 'Execute Ruby in an explicitly selected SketchUp instance with that process’s privileges.',
        note: 'These switches apply to every SketchUp connection on this Host. Saved changes synchronize automatically; tool calls still require explicit confirmation.',
        unavailable: 'Configuration is not ready. Enable the bridge plugin and reopen this page.',
        readOnly: 'This connection cannot change configuration.',
        save: 'Save', saving: 'Saving…', saved: 'Saved', discard: 'Discard changes',
        failed: 'The save was refused, possibly because configuration changed elsewhere. Your choices are preserved; reopen the page to review current values before saving.',
      },
    }

    function Permissions({ t, form }) {
      // draft 同时保存开始编辑时的 revision，避免覆盖其它页面的并发修改。
      const [draft, setDraft] = useState(null)
      const [saving, setSaving] = useState(false)
      const [notice, setNotice] = useState('')
      const pending = useRef(false)
      const state = form?.state
      if (state?.status !== 'ready' || !state.value) return h('p', { role: 'status' }, t('unavailable'))
      const values = draft?.values ?? state.value
      const disabled = saving || !state.writable
      const update = (key, value) => {
        setNotice('')
        setDraft(previous => ({
          revision: previous?.revision ?? state.revision,
          values: { ...(previous?.values ?? state.value), [key]: value },
        }))
      }
      const save = async (event) => {
        event.preventDefault()
        if (!draft || pending.current || !state.writable) return
        pending.current = true
        setSaving(true)
        setNotice('')
        try {
          const accepted = await form.mutate(fields.map(key => ({ op: 'set', path: [key], value: draft.values[key] })), draft.revision)
          if (accepted !== true) { setNotice(t('failed')); return }
          setDraft(null)
          setNotice(t('saved'))
        } catch (error) {
          setNotice(`${t('failed')} ${error instanceof Error ? error.message : String(error)}`)
        } finally {
          pending.current = false
          setSaving(false)
        }
      }
      return h('form', { onSubmit: save, style: { maxWidth: 640, display: 'grid', gap: 18 } },
        h('h3', { style: { margin: 0 } }, t('permissions')),
        ...fields.map(key => h('label', { key, style: { display: 'grid', gridTemplateColumns: '20px 1fr', gap: 10, alignItems: 'start' } },
          h('input', { type: 'checkbox', checked: values[key] === true, disabled, onChange: event => update(key, event.target.checked), style: { marginTop: 4 } }),
          h('span', null, h('span', { style: { fontWeight: 600 } }, t(key)), h('small', { style: { display: 'block', marginTop: 5, opacity: 0.75, lineHeight: 1.5 } }, t(`${key}Hint`))),
        )),
        h('p', { style: { margin: 0, opacity: 0.75, lineHeight: 1.5 } }, t('note')),
        !state.writable && h('p', { role: 'status' }, t('readOnly')),
        h('div', { style: { display: 'flex', gap: 10 } },
          h('button', { type: 'submit', disabled: disabled || !draft }, t(saving ? 'saving' : 'save')),
          h('button', { type: 'button', disabled: saving || !draft, onClick: () => { setDraft(null); setNotice('') } }, t('discard')),
        ),
        h('p', { role: 'status', 'aria-live': 'polite', style: { margin: 0 } }, notice),
      )
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, dictionaries), 'sketchup: settings locale')
        ctx.effect(() => ctx.slots.inject('plugins.row.config', () => ctx.slots.register({
          name: 'plugins.row.config',
          key: '@leolee9086/dsh-sketchup#bridge-sketchup',
          locale: NS,
        }, props => props.view === 'summary' ? props.t('summary') : h(Permissions, props))), 'sketchup: configuration page')
      },
    }
  },
})
