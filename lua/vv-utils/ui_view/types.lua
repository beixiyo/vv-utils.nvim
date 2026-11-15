-- vv-utils.ui_view 的类型

---@class VVUIViewTab
---@field id string
---@field label string
---@field key? string 直接跳到该标签的键，同时显示在标签上

---@class VVUIViewItem
---@field id string 当前页内唯一；重绘后按它恢复光标
---@field row VVUIRowsRow|VVUIRowsChunk[]|string 条目行
---@field detail? (VVUIRowsRow|VVUIRowsChunk[]|string)[]|fun(): (VVUIRowsRow|VVUIRowsChunk[]|string)[] 展开后显示的行；函数形态在展开时才求值
---@field data? any 调用方数据，动作回调里原样取回

---@class VVUIViewSection
---@field id string
---@field title? string|VVUIRowsChunk[] 分组标题；省略时条目不缩进、不显示标题行
---@field count? integer|string|false 标题后的计数；false 不显示 @default 条目数
---@field items VVUIViewItem[]

---@class VVUIViewPage
---@field header? (VVUIRowsRow|VVUIRowsChunk[]|string)[] 标签栏之下、分组之上的说明行
---@field sections VVUIViewSection[]
---@field empty? VVUIRowsRow|VVUIRowsChunk[]|string 所有分组都没有条目时显示
---@field title? string|VVUIRowsChunk[] 浮窗边框上的标题；每次刷新写入，用于显示会变化的统计。省略时保持打开时的 title

---@class VVUIViewAction
---@field key string|string[] 多个键共用一个动作时，页脚只显示第一个
---@field desc string 英文动作名，用于页脚提示与映射 desc
---@field run fun(view: VVUIViewHandle, item: VVUIViewItem?) item 为光标所在条目，光标不在条目上时为 nil
---@field hint? boolean|'all' 是否出现在页脚提示里；'all' 把多个键都显示出来（`↵/r Restore`） @default true
---@field tab? string|string[] 只在这些标签下生效并显示提示；缺省所有标签

---@class VVUIViewConfig
---@field page fun(view: VVUIViewHandle): VVUIViewPage 返回当前标签要显示的内容；每次刷新调用
---@field title? string 浮窗边框上的标题
---@field brand? string 标签栏最左侧的醒目色块，通常是界面名
---@field width VVUIWindowSize|'content' 'content' 按最宽的一行与页脚提示定宽，每次刷新后重排 @default 0.8
---@field height VVUIWindowSize|'content' 'content' 按行数定高，每次刷新后重排 @default 0.8
---@field min_width integer `width = 'content'` 时的最小宽度 @default 40
---@field border string|string[] @default 'rounded'
---@field backdrop boolean|integer 背景遮罩，见 ui_window.open_float @default true
---@field filetype string @default 'vv-view'
---@field desc_prefix string 映射 desc 的前缀，供 help_panel 反读 @default 'vv-view'
---@field tabs VVUIViewTab[] @default {}
---@field tab? string 初始标签 @default 第一个标签
---@field actions VVUIViewAction[] @default {}
---@field expand_key string|false 展开或收起详情的键；false 不绑 @default '<CR>'
---@field close_keys string[] @default { 'q', '<Esc>' }
---@field section_keys boolean 绑定 `]]` / `[[` 在分组之间跳转；只有一个分组的界面可以关掉 @default true
---@field on_tab? fun(view: VVUIViewHandle, id: string) 标签切换后、重绘前调用
---@field on_close? fun() 关闭后调用一次；`:q` 等外部方式关闭时在 WinClosed 里同步调用

---@class (partial) VVUIViewOpts: VVUIViewConfig
---@field page fun(view: VVUIViewHandle): VVUIViewPage

---@class VVUIViewLine
---@field kind 'tabs'|'section'|'item'|'detail'|'text'
---@field id? string 条目或分组 id

---@class VVUIViewHandle
---@field buf integer
---@field win integer
---@field refresh fun() 重新调用 page 并整页重绘，按条目 id 保持光标
---@field item fun(): VVUIViewItem?
---@field line_of fun(id: string): integer?
---@field pos_of fun(id: string): integer?, integer? 行号与内容起始列
---@field item_width fun(grouped?: boolean): integer 一个条目行最多能占的显示列数，供调用方截断长内容
---@field tab fun(): string?
---@field set_tab fun(id: string)
---@field cycle_tab fun(step: integer)
---@field toggle fun(id?: string, state?: boolean)
---@field is_expanded fun(id: string): boolean
---@field focus fun(id: string)
---@field is_open fun(): boolean
---@field close fun() 幂等

return {}
