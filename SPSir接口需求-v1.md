# HowDoI ↔ SPSir 接口需求 v1

日期：2026-10-11。状态：供两侧适配开发使用的规范草案，接口尚未实现、未实机验证。

## 1. 已确认决策与设计默认

用户已确认：两个独立应用；先完成 HowDoI 基础路书；现在明确数据规则与传递接口，SPSir 可以据此开发适配。第一版路书只有预算，不提前启用实际开支录入或跨应用调用。

本文选择以下最小设计默认：联动 v1 只支持个人事件的支出新增、来源记录查询和 SPSir 内修改/删除后的结果回传；公共事件、收入、退款、跨应用修改删除、云服务和整个账本同步不在范围内。这些是为降低复杂度而给出的工程默认，不是用户逐项确认的功能要求。

接口提供一次授权后的提交能力。未来客户端默认让用户明确点击“记入 SPSir”；是否启用保存即提交的开关，留待联动阶段确定。SPSir 接口不必为两种客户端触发方式开发两套协议。

## 2. 数据归属与基础阶段预留

| 数据 | 权威来源 | 规则 |
| --- | --- | --- |
| 旅行、活动、交通、住宿、排序 | HowDoI | 沿用路书双端同步规则 |
| 预算、计划汇率 | HowDoI | 不构成实际支出，不因活动完成而入账 |
| 未提交的实际开支草稿（后续） | HowDoI | 可在电脑或手机输入，未确认不得称作已入账 |
| 正式账目、实际人民币金额、分类 | SPSir | 入账后在 SPSir 编辑/删除；HowDoI 查询并展示快照 |
| 来源去重映射与删除状态 | SPSir | 用于防止重试、恢复或旧设备重复记账 |
| 设备授权 | SPSir 本机 | 不参与路书双端同步或备份导出 |

基础路书阶段现在要做的事情：

- 旅行 tripId、活动/交通/住宿 itemId、预算 budgetItemId 用不透明 UUID 字符串；创建后不因改名、排序或换日期变化。
- 双端同步保留相同 ID；导入为新旅行副本时重新分配 ID，避免误绑定原来的账目。
- 预算金额与币种独立于界面，金额采用精确十进制/最小单位，禁止浮点货币运算。
- 预留通过独立功能模块调用本协议的边界；第一版仅交付规范，不建立空连接器、空实际账目表或不可用按钮。

后续实际开支使用独立 expenseId。一笔预算可以对应多笔支付；一项活动也可有多笔实际开支。expenseId 不得复用 budgetItemId 或 SPSir entryId。

SPSir 正式账目不使用路书“最后修改时间优先”合并。更改旅行、预算汇率、活动状态，均不更新或删除已入账记录。

## 3. 传输边界

建议 Android 本机使用 ContentProvider.call 承载少量 JSON 请求，授权选择事件使用显式 Activity。Windows 不直接访问 SPSir，不启动手机 HTTP 记账服务，不共享数据库文件。

以下为拟定公开标识，尚非 SPSir 现有能力：

- SPSir package：`com.spsir.ledger`（现有）。
- Provider authority：`com.spsir.ledger.integration`。
- 授权 Activity action：`com.spsir.ledger.action.AUTHORIZE_EVENT`，调用方显式指定 SPSir package。
- Provider call：method 为下文操作名，arg 为 null，extras 中 `requestJson` 为 UTF-8 JSON 字符串；响应 Bundle 中 `responseJson` 为 JSON 字符串。
- 授权 Activity 输入 `requestJson`，输出 `responseJson`，使用可取得调用方身份的 Activity result 流程。取消返回 RESULT_CANCELED，无写入和授权。
- HowDoI 最终 Android 包名和正式签名指纹尚未分配。不得把示例来源字符串当作身份，不得要求更换 SPSir 原签名。生产调用方必须在接入发布前确定。
- HowDoI 仅声明所需 SPSir package/authority 可见性，不申请 QUERY_ALL_PACKAGES。

所有 calls 放在客户端工作线程，避免阻塞界面。单请求/响应上限 128 KiB（UTF-8）；记录批量最多 50 项，读目录分页最多 50 项。超限返回错误，不静默截断。

接口 v1 是本机 IPC 协议，不是 HTTP API，不提供 OpenAPI/网络监听作为附带功能。

## 4. 授权模型

1. HowDoI 查询公开 capabilities，随后在用户操作下打开 SPSir 授权页。
2. SPSir 从系统取得实际调用方 package/UID 及其已安装签名身份，不信任请求 JSON 中的 sourceApp、包名或应用显示名。调用方无法验证时拒绝。
3. SPSir 页面显示实际应用身份及权限范围，让用户选择一个现有个人事件。没有事件时，用户可在 SPSir 现有界面先建事件；协议 v1 不提供远程创建事件。
4. 用户确认授权“向该事件新增本人支出，并读取由该来源提交的记录”，返回 bindingId。归档/公共事件不可新绑定。
5. 绑定关联真实调用方身份、tripId、eventId、ledgerEpoch；bind ID 只是引用，不是可转交的通行证。
6. 每次受保护调用再次验证系统调用方、签名、bindingId、当前账本代次、操作范围。使用成熟平台签名校验；正常签名轮换需验证合法签名历史，不信任文本哈希。
7. SPSir 设置中可撤销绑定；撤销后所有受保护 calls 返回 AUTH_REQUIRED。查询 capabilities 不泄露事件、类别使用记录或账目。

特别要求：ContentProvider.call 的自定义方法不能依赖默认读写权限自动拦截，必须逐调用检查。进入后台任务或清除 Binder 身份前先捕获并验证调用身份。未实现的 query/insert/update/delete/openFile 等入口统一拒绝，不能通过其他入口绕过授权。

不假定两应用使用同一签名。授权不通过广播、剪贴板、可公开解析的深链或共享 JSON 文件传递账本权限。调用方也应验证目标确为受信任 SPSir 安装包；正式签名校验纳入发布配置，不把私钥放入项目。

## 5. 通用协议

每个请求字段：`protocolVersion`（整数，v1 固定 1）、`requestId`（UUID，调用关联标识）、`payload`（对象）。受保护请求还必须携带 `bindingId` 和 `ledgerEpoch`（非空不透明字符串）。重复提交时 requestId 可以相同或重新生成；去重不能只依赖 requestId。

成功响应：`protocolVersion`、原 `requestId`、`ok: true`、`data`。
失败响应：`protocolVersion`、原 `requestId`、`ok: false`、`error: {code, message, retryable, field?}`。`field` 为出错字段路径，可省略。不得返回原始 SQL、异常堆栈或其他账目信息。

无法解析 requestId 时失败响应 requestId 为 null。协议版本不支持时不得写数据。平台 SecurityException 或进程连接失败由客户端映射为授权/传输失败，不能要求系统异常都能封装成 JSON。

未知附加字段可忽略；未知操作、非法必填字段和枚举必须拒绝。v1 不新增必填字段；破坏兼容的变更升级协议版本。API 协议版本、数据库版本、备份版本各自独立。

## 6. 操作清单

### capabilities（公开，只读）

payload 为 `{}`。返回 `supportedProtocolVersions: [1]`、`operations: ["capabilities", "catalog", "createExpense", "getExpenses"]`、`authorizationAction`、`maxBatchSize: 50`、`maxPayloadBytes: 131072`。不返回私人数据。若接口不存在，客户端显示需要更新 SPSir，不使用备份覆盖作为替代。

### AUTHORIZE_EVENT（Activity，用户确认）

payload：`tripId`（UUID）、`tripName`（1～200 个 UTF-16 code units，仅供展示，不自动用作事件名称）。返回 `bindingId`、`ledgerEpoch`、`event: {id, name, kind: "personal", archived: false}`、`scopes: ["expense.create", "expense.readOwn"]`。

同一调用身份 + 当前代次 + tripId 已有有效绑定时可返回原绑定；换绑不同事件必须在 SPSir 中明确确认，旧绑定撤销，不迁移旧账目。账目去重键不包含 bindingId，重新授权不能绕过去重。

### catalog（受保护，只读）

payload：`offset`（非负整数，默认 0）、`limit`（1～50，默认 50）、`catalogRevision`（首次省略；后续页传返回值）。

返回当前绑定 `event`（id/name/kind/archived）、`ledgerEpoch`、`currencySpecs`（code/minorDigits/maxMajor）、`categories`（id/name/parentId/groupName/selectable）、`nextOffset`（结束为 null）、`catalogRevision`。

只返回适用于新增支出的可选细分类，按稳定 ID 排序；不传用户使用频率或账目。币种表每页可重复返回。隐藏的大类及其细类、隐藏细类不作为新录入候选。目录变化导致分页版本不一致时返回 CATALOG_CHANGED，客户端从第一页重读。categories 中 selectable 固定为 true，给未来兼容留出明确语义。

SPSir 当前支持 CNY/EUR/NOK/SEK/DKK/ISK/USD/GBP/JPY，JPY 和 ISK 精度 0，其余为 2；客户端以实际返回为准，不将固定列表写死。

### createExpense（受保护，单笔事务提交）

payload 字段：

| 字段 | 类型与约束 |
| --- | --- |
| tripId | UUID，必须等于绑定旅行 |
| expenseId | UUID，独立支付标识，确定后永不复用 |
| itemId | UUID 或 null，对应活动/交通/住宿，仅作为来源关联 |
| budgetItemId | UUID 或 null，仅作预算关联，不参与去重 |
| currency | 大写币种 code，必须在目录中 |
| originalMinor | 正整数的十进制字符串，不含符号、小数点、指数和前导零 |
| rmbMinor | 同上，单位人民币分；CNY 必须与 originalMinor 相同 |
| categoryId | 当前可用的 SPSir 支出细分类 ID，不是分类名称 |
| occurredOn | 有效 ISO 日期 YYYY-MM-DD；用户确认的消费当地记账日，不按手机或 UTC 自动换日 |
| note | 字符串，默认空，最多 500 个 UTF-16 code units，与 Kotlin String.length 一致 |

source 身份、eventId 由系统身份和 binding 得到，不接受客户端任意指定。金额为最小货币单位字符串，避免跨语言 JSON 数值精度丢失；SPSir 使用 checked Long/BigDecimal 校验，原币与人民币金额均大于 0，换算为主单位均不超过当前 999999999 上限。不按预算汇率自动填写已确认人民币金额。

JSON 示例为虚构样例，binding/epoch/分类须替换为实际返回值：

```json
{
  "protocolVersion": 1,
  "requestId": "9cd43c85-6d83-48e1-85ac-f4a54f86b5c7",
  "bindingId": "binding-example",
  "ledgerEpoch": "epoch-example",
  "payload": {
    "tripId": "9230c04e-c8f4-40b7-bf5b-2186c735f61c",
    "expenseId": "3ef628d3-a7ec-433b-9a36-5280c04203ac",
    "itemId": "8068a61e-dfc3-427c-a901-567118daef2a",
    "budgetItemId": null,
    "currency": "EUR",
    "originalMinor": "1250",
    "rmbMinor": "9750",
    "categoryId": "food.breakfast",
    "occurredOn": "2026-10-11",
    "note": "早餐"
  }
}
```

含义：12.50 欧元，已确认人民币 97.50 元；不是自动计算实时汇率。

成功 data：`outcome: "created" | "alreadyExists"` 及 `record`。record 字段：`expenseId, entryId, revision, state, itemId, budgetItemId, entry`。revision 为递增正整数的十进制字符串，仅代表 SPSir 此来源记录版本，不比较设备时钟。state 为 active/deleted/detached；entry 在 active 时为 `{kind: "expense", originalMinor, currency, rmbMinor, categoryId, eventId, occurredOn, note}`，所有金额仍为字符串；deleted/detached 时 entry 为 null。

### getExpenses（受保护，按来源查询）

payload：`tripId`、`expenseIds`（1～50 个唯一 UUID）。只查询调用方、当前代次和授权旅行/事件内的来源记录，不支持任意 SPSir entryId 或整个事件账目读取。

返回 `records`，按请求顺序逐项返回。已知项为上述 record；未知项返回 `{expenseId, state: "missing", entryId: null, revision: null, itemId: null, budgetItemId: null, entry: null}`。missing 不等于 deleted，不得自动补记。

无需服务器推送或变更游标。HowDoI 在打开、切回应用及前台需要更新时按已知 expenseIds 分批查询；本地保留其已提交标识即可。超出当前授权事件的已关联记录返回 detached 且不泄露新事件/金额。

## 7. 去重与状态规则

唯一来源键：`sourceIdentity + tripId + expenseId`（当前 SPSir 数据库内）。sourceIdentity 由真实调用包名与受信任签名身份派生，不是客户端自报字符串；不含绑定 ID 或 requestId。

新增流程在一个事务内完成：校验身份/代次/绑定 → 查询来源键 → 如已存在核对原始提交内容 → 如不存在校验事件/金额/币种/分类 → 保存正式账目和来源映射 → 提交后才返回成功。

- 相同来源键、相同规范化业务字段：返回 alreadyExists 和当前 record，不重复写入、不增加版本。即使账目后被 SPSir 修改或删除也不能重新创建。
- 相同来源键、不同业务字段：SOURCE_CONFLICT，不把 create 当作修改接口。规范化定义为金额/币种按约束原样、合法 UUID 统一小写、note trim 后值、可选关联缺省视为 null；绑定/请求 ID 不参与业务比较。
- 原始请求规范化字段必须保存或保留可可靠比较的表达，不能与已被 SPSir 修改后的 entry 比较，否则重试会错误冲突。
- 同时提交依赖数据库唯一约束和事务保证只产生一笔，不只做内存查重。
- 已存在来源的查询/同内容重试，在事件后来归档时仍可返回结果；归档只阻止新写入。撤销授权仍拒绝读取。
- SPSir 内编辑来源账目时递增 revision；删除时保留来源墓碑并递增版本，不删除来源键。
- 用户在 SPSir 将账目解除事件关联或移到别的事件时，不阻止现有功能；来源映射保留，查询返回 detached。重新移回授权事件后可返回 active 并递增版本。
- 新绑定其他事件后用同一 expenseId 提交，若该来源已属于旧事件，返回 SOURCE_CONFLICT；不得复制或移动旧账目。
- 删除路书旅行/活动不会调用 SPSir 删除。v1 不提供 updateExpense/deleteExpense，不自动退款。

客户端后续状态：draft → pending → posted；确认 deleted/detached 后显示相应终态；校验失败为 needsAttention；授权/账本代次变化为 needsReconcile。超时或回执丢失保持 pending/结果未知，用原 expenseId 和原内容查询或重试，不能生成新 ID 猜测补记。已发出且结果未知的内容冻结，核对结果前不改同一支付内容。

Windows 草稿经路书同步交给指定安卓设备提交；只有手机保存提交回执并同步后，电脑才显示已入账。通过 ledgerEpoch + expenseId 关联回执，不能用路书修改时间覆盖已确认状态。v1 只支持一台指定手机连接一个 SPSir 账本实例。

## 8. 恢复、备份与账本代次

ledgerEpoch 是 SPSir 本地账本代次标识。初始化、全量覆盖恢复或账本重置时生成新值；普通新增/修改、应用正常升级不变。覆盖恢复即使是同一备份也换代次，所有旧绑定撤销。旧请求返回 LEDGER_CHANGED，绝不自动重新提交旧队列。

SPSir 新格式备份需保存来源映射、原始提交字段、删除墓碑及 revision；不导出授权凭据/绑定。恢复后重新授权，查询历史来源进行人工核对。旧格式备份缺失来源映射时，不能按日期金额自动认定同一笔，也不能自动重放 pending 数据，应提示在 SPSir 核对。

HowDoI 导入为新旅行时重分配旅行/活动/预算 ID，不导入可执行提交队列或有效 binding。实际账目参考可只读保留为待核对历史，不自动入账。清除任一应用数据后必须重新授权与核对。

## 9. 错误码

| code | retryable | 处理 |
| --- | --- | --- |
| UNSUPPORTED_VERSION / UNSUPPORTED_OPERATION | false | 升级或关闭联动入口 |
| INVALID_REQUEST / PAYLOAD_TOO_LARGE / VALIDATION_ERROR | false | 修正字段或拆分查询 |
| AUTH_REQUIRED / PERMISSION_DENIED | false | 重新授权或拒绝调用 |
| LEDGER_CHANGED | false | 停止队列，重新绑定并核对 |
| EVENT_NOT_FOUND / EVENT_ARCHIVED / PUBLIC_EVENT_UNSUPPORTED | false | 在 SPSir 处理事件；不自动改绑 |
| CURRENCY_UNSUPPORTED / CATEGORY_UNAVAILABLE | false | 刷新目录并由用户修正 |
| CATALOG_CHANGED | true | 从第一页重新读目录 |
| SOURCE_CONFLICT | false | 核对来源记录，不能更换 ID 自动再提交 |
| TEMPORARILY_UNAVAILABLE / INTERNAL_ERROR | true | 有界重试；仍使用原来源 ID |

客户端本地状态 APP_NOT_INSTALLED、API_UNAVAILABLE、TRANSPORT_ERROR 不伪装成 SPSir 返回码。传输失败时是否已入账未知。错误 message 面向用户，逻辑只判断 code；日志不输出完整账目、身份令牌或授权内容。

## 10. SPSir 适配工作清单

1. 增加授权 Activity 和独立 Provider（不能复用当前文件分享 Provider）；按第 4 节实现每次调用的身份与范围检查。
2. 增加持久化的账本代次、授权绑定及外部来源映射。来源映射包含唯一来源键、原始提交内容、entryId、所属事件、revision、删除状态。可用最少表实现，不改写原账本结构。
3. 复用现有 LedgerRepository、Money、归档校验及事务流程。导入只能创建 expense，SPSir 自行生成 entryId；禁止客户端指定 ID 覆盖已有流水。补充新增时可选分类校验，但不改变历史分类编辑兼容行为。
4. 普通 UI 修改、删除、事件解除/迁移的路径同步维护来源状态和 revision，避免只有接口路径正确。公共费用原流程不受影响。
5. 当前数据库 v4、新增迁移按接手时真实最新版本递增，不硬编码假定无人并行开发。保留旧数据，禁止破坏性重建。备份当前 v3，按实际最新版增加兼容格式；旧备份继续可读。
6. 更新备份恢复与授权撤销流程，恢复和新 epoch 提交保持原子性，不能出现旧绑定对新账本有效的窗口。
7. 保持 SPSir 正式签名和应用 ID；不重装有真实数据的应用作为开发步骤。

## 11. HowDoI 后续适配清单

基础版本只落实第 2 节稳定 ID、精确预算和数据边界。联动阶段再增加实际支出草稿、SPSir 事件绑定、币种/分类目录、提交队列与结果快照、Android 平台桥接和状态显示。联动未启用时，路书所有功能独立可用。

联调前交换：HowDoI 正式包名/签名标识、SPSir 集成测试包版本、最终公开 authority/action、协议版本及一份 capabilities 输出。无需交换任何签名私钥。

## 12. 接口验收场景

| 场景 | 必须结果 |
| --- | --- |
| 人民币支出与欧元示例 | 金额、日期、类别和绑定事件正确；例中 EUR 1250 对应 12.50，CNY 9750 对应 97.50 |
| 同一请求连续/并发提交两次 | 恰好一条账目；后者 alreadyExists |
| SPSir 提交成功但回执丢失 | 查询或原请求重试恢复状态，不再建账 |
| 同来源 ID 改金额再次 create | SOURCE_CONFLICT，账目不变 |
| SPSir 修改后客户端重试原请求 | 返回最新 record，不覆盖修改且不重复记账 |
| SPSir 删除后重试 | 返回 deleted，不能复活 |
| SPSir 将账目移出事件 | 返回 detached，不泄露移往其他事件的详情 |
| 归档、公共事件、隐藏分类、不支持币种 | 明确失败，无部分写入 |
| 未授权/伪造包名/复制 binding/调用未开放入口 | 拒绝读取与写入 |
| 撤销授权、恢复备份后旧请求 | 分别拒绝授权或返回 LEDGER_CHANGED |
| 旧备份无来源映射 | 停止自动补记，要求核对 |
| Windows 离线草稿 | 仍待入账；手机确认后才 posted |
| 删除路书/改预算汇率 | SPSir 实际账目不变 |
| 旧数据库升级与普通/公共记账回归 | 历史数据及统计不变 |
| 超长备注、溢出金额、错误日期、批量超限 | 校验失败，不崩溃或截断入账 |

需要通过真实双应用测试验证权限、Activity 返回、进程重启和 IPC；本文示例与规范检查不等于运行通过。

## 13. 核查依据

本地代码只读核查：`D:\SPSir\app\src\main\java\com\spsir\ledger\LedgerDatabase.kt`、`LedgerViewModel.kt`、`Money.kt`，以及 Manifest、README。现有模型和校验限制用于制定本协议，不表明其接口已存在。

- [Android ContentProvider API：call 与调用方身份](https://developer.android.com/reference/android/content/ContentProvider)
- [Android 包可见性声明](https://developer.android.com/training/package-visibility/declaring)

以上官方机制于 2026-10-11 核查。当前交付为设计文档，未修改 SPSir 或编写 HowDoI 应用代码。
